import AppKit
import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

nonisolated private let routerLogger = SupaLogger("RemoteAccess")

/// Answers the phones behind the relay: `hello`, `list`, terminal
/// `attach` / `detach` / `input`, `tab.new` and `suggest`
/// (`docs/remote-access-protocol.md`). One instance per app, started at launch
/// when `~/.config/supacode/remote-access.json` enables it.
@MainActor
final class RemoteHostRouter {
  static let fallbackGrid = (columns: 160, rows: 48)
  /// The largest grid a phone-opened tab starts at while the Mac does not show
  /// it, unless the phone asks for a size; it would otherwise take the whole
  /// Mac window or screen.
  static let newTabGrid = (columns: 120, rows: 40)
  static let sizePollInterval: Duration = .seconds(2)
  static let suggestionContextRows = 80
  static let wakeTimeout: Duration = .seconds(6)
  /// How long a `tab.new` waits for the new tab to appear in the layout.
  static let tabNewTimeout: Duration = .seconds(10)
  static let tabNewPollInterval: Duration = .milliseconds(100)
  /// How long a `hello` from a same-network phone may wait for a LAN endpoint
  /// that is still starting before it is answered without `lan`.
  static let helloLANWait: Duration = .seconds(3)

  private struct Attachment {
    let contentID: UUID
    let stream: ZmxRemoteStream
    let pump: Task<Void, Never>
    let sizeWatch: Task<Void, Never>
  }

  private let source: RemoteSnapshotSource
  private var connection: RemoteRelayConnection?
  /// Phones the relay announced, each with at most one attached terminal.
  private var clients: [String: Attachment?] = [:]
  /// `tab.new` waits in flight per phone, cancelled when that phone's
  /// connection ends so a reused connId never gets a stale answer.
  private var tabNewWaits: [String: [UUID: Task<Void, Never>]] = [:]
  /// Phones with a suggestion in flight.
  private var suggesting: Set<String> = []
  /// Relay phones the relay saw on the Mac's own network (`conn.open`).
  private var sameNetwork: Set<String> = []
  /// Authenticated LAN phones and how to reach them; every other connID is a relay one.
  private var lanSinks: [String: (String) -> Void] = [:]
  private var lanServer: RemoteLANServer?
  /// The LAN start in flight (identity load, listener start, until the listener
  /// is ready or failed); nil before it, once it ended, and after `stop()`.
  private var lanStart: Task<Void, Never>?
  private var clientKey: String?
  /// Bounds the wait of a delayed `hello` (`helloLANWait`).
  private let clock: any Clock<Duration>
  /// The name every `hello` carries (ИД4); `rename(to:)` updates it.
  private(set) var hostName: String
  /// This Mac's relay id (ИД1), sent in `hello` so a phone can tell its Macs apart.
  let hostID: String?
  /// The missing-hardware-UUID warning goes out once per process, not per start.
  private static var warnedMissingHostID = false

  init(
    source: RemoteSnapshotSource,
    hostName: String,
    hostID: String?,
    clock: any Clock<Duration> = ContinuousClock()
  ) {
    self.source = source
    self.hostName = hostName
    self.hostID = hostID
    self.clock = clock
  }

  nonisolated deinit {}

  /// Read-only status for the Remote Access settings pane.
  var isRelayConnected: Bool { connection?.isConnected ?? false }
  var lanPort: UInt16? { lanServer?.port }
  var isLANStarting: Bool { lanStart != nil }

  /// Starts the host when remote access is configured; nil otherwise (and
  /// always nil inside a test process).
  static func startIfConfigured(
    store: StoreOf<AppFeature>,
    terminalManager: WorktreeTerminalManager
  ) -> RemoteHostRouter? {
    guard NSClassFromString("XCTestCase") == nil else { return nil }
    guard
      RemoteAccessConfig.mayHost(
        bundlePath: Bundle.main.bundlePath,
        override: ProcessInfo.processInfo.environment[RemoteAccessConfig.overrideVariable]
      )
    else {
      routerLogger.info("Remote access skipped: not the installed app (set SUPACODE_REMOTE_ACCESS=1 to force)")
      return nil
    }
    guard let config = RemoteAccessConfig.load() else { return nil }
    let hostID = RemoteAccessConfig.currentHostID
    if hostID == nil, !warnedMissingHostID {
      warnedMissingHostID = true
      routerLogger.warning("No hardware UUID; the relay files this Mac as the legacy host")
    }
    let hostName = RemoteAccessConfig.displayName(
      configured: config.hostName, computerName: RemoteAccessConfig.computerName)
    let router = RemoteHostRouter(
      source: RemoteSnapshotSource(store: store, terminalManager: terminalManager),
      hostName: hostName,
      hostID: hostID
    )
    let connection = RemoteRelayConnection(
      config: config,
      hostID: hostID,
      hostName: hostName,
      onText: { [weak router] text in router?.receive(text) },
      onConnectionChange: { [weak router] connected in
        if !connected { router?.dropAllClients() }
      }
    )
    router.connection = connection
    connection.start()
    // The relay URL is private (docs/remote-access.md); never log it.
    routerLogger.info("Remote access host started")
    if config.lan, let clientKey = RemoteAccessConfig.loadClientKey() {
      router.beginLAN(clientKey: clientKey)
    }
    return router
  }

  /// Loads the identity and starts the LAN listener, tracked in `lanStart` until
  /// the listener is ready or failed, so a `hello` that arrives meanwhile can wait.
  private func beginLAN(clientKey: String) {
    self.clientKey = clientKey
    lanStart = Task { [weak self] in
      // Creating the certificate runs openssl; keep it off the main actor.
      let identity = await Task.detached(operation: { RemoteLANIdentity.loadOrCreate() }).value
      // `stop()` cancels this task and already cleared `lanStart`.
      guard !Task.isCancelled, let self else { return }
      if let identity {
        self.startLAN(identity: identity, clientKey: clientKey)
        if let server = self.lanServer { _ = await server.waitUntilReady() }
      } else {
        routerLogger.warning("LAN shortcut off: no TLS identity")
      }
      guard !Task.isCancelled else { return }
      self.lanStart = nil
    }
  }

  private func startLAN(identity: RemoteLANIdentity.Loaded, clientKey: String) {
    // The identity loads asynchronously; `stop()` may have run meanwhile.
    guard connection != nil, lanServer == nil else { return }
    let server = RemoteLANServer(
      identity: identity,
      clientKey: clientKey,
      callbacks: .init(
        opened: { [weak self] connID, send in self?.lanOpened(connID, send: send) },
        received: { [weak self] connID, text in self?.receiveDirect(connID: connID, json: Data(text.utf8)) },
        closed: { [weak self] connID in self?.lanClosed(connID) }
      )
    )
    lanServer = server
    server.start()
  }

  // MARK: - LAN shortcut

  private func lanOpened(_ connID: String, send: @escaping (String) -> Void) {
    lanSinks[connID] = send
    clients[connID] = .some(nil)
    routerLogger.info("LAN shortcut: phone connected as \(connID)")
  }

  private func lanClosed(_ connID: String) {
    cancelTabNewWaits(connID: connID)
    detach(connID: connID)
    clients[connID] = nil
    lanSinks[connID] = nil
    suggesting.remove(connID)
  }

  /// What a relay phone needs to try the LAN: only for phones on the Mac's
  /// network, and only while the listener runs.
  private func lanCandidate(for connID: String) -> RemoteLANCandidate? {
    guard sameNetwork.contains(connID), let server = lanServer, let port = server.port, let clientKey else {
      return nil
    }
    let addresses = RemoteLANServer.lanAddresses()
    guard !addresses.isEmpty else { return nil }
    return RemoteLANCandidate(
      addrs: addresses,
      port: Int(port),
      fp: server.fingerprint,
      fpMac: RemoteLANIdentity.fingerprintMAC(fingerprint: server.fingerprint, clientKey: clientKey)
    )
  }

  /// Applies a name saved in Settings at once: the next `hello` (relay and LAN)
  /// carries it, and the relay learns it without a reconnect (ИД3). A blank
  /// name falls back to the computer name (ИД4).
  func rename(to name: String) {
    let resolved = RemoteAccessConfig.displayName(configured: name, computerName: RemoteAccessConfig.computerName)
    hostName = resolved
    connection?.rename(resolved)
  }

  func stop() {
    lanStart?.cancel()
    lanStart = nil
    lanServer?.stop()
    lanServer = nil
    for connID in Array(lanSinks.keys) { lanClosed(connID) }
    dropAllClients()
    connection?.stop()
    connection = nil
  }

  // MARK: - Inbound

  func receive(_ text: String) {
    guard let frame = RemoteHostFrame.parse(text) else { return }
    receiveDirect(connID: frame.connID, json: frame.json)
  }

  /// One application message from a phone, relayed or over the LAN.
  func receiveDirect(connID: String, json: Data) {
    guard let message = RemoteJSON.decodeInbound(json) else { return }
    switch message.t {
    case "conn.open":
      if clients[connID] == nil { clients[connID] = .some(nil) }
      if message.sameNetwork == true { sameNetwork.insert(connID) } else { sameNetwork.remove(connID) }
    case "conn.close":
      cancelTabNewWaits(connID: connID)
      detach(connID: connID)
      clients[connID] = nil
      sameNetwork.remove(connID)
    case "hello":
      clients[connID] = clients[connID] ?? .some(nil)
      if Self.helloWaitsForLAN(sameNetwork: sameNetwork.contains(connID), lanStarting: lanStart != nil),
        let start = lanStart
      {
        answerHelloWhenLANReady(connID, start: start)
      } else {
        replyHello(connID)
      }
    case "list":
      reply(connID, source.listMessage(id: message.id))
    case "attach":
      attach(connID: connID, message: message)
    case "detach":
      // A late detach for a tab the phone already left must not drop the
      // newer attachment: honor the contentId when it is given.
      if let raw = message.contentId, case .some(.some(let current)) = clients[connID],
        UUID(uuidString: raw) != current.contentID
      {
        return
      }
      detach(connID: connID)
    case "input":
      input(connID: connID, message: message)
    case "suggest":
      suggest(connID: connID, message: message)
    case "tab.new":
      newTab(connID: connID, message: message)
    default:
      replyError(connID, id: message.id, "unknown message type: \(message.t)")
    }
  }

  // MARK: - Hello

  private func replyHello(_ connID: String) {
    reply(connID, helloMessage(for: connID))
  }

  /// The `hello` answer for one phone: name, id and, for a same-network phone, `lan`.
  func helloMessage(for connID: String) -> RemoteHelloMessage {
    RemoteHelloMessage(host: hostName, hostId: hostID, lan: lanCandidate(for: connID))
  }

  /// Answers a same-network phone's `hello` once the LAN start ends, or after
  /// `helloLANWait` without `lan`; dropped when the phone left or the host stopped.
  private func answerHelloWhenLANReady(_ connID: String, start: Task<Void, Never>) {
    let clock = self.clock
    Task { [weak self] in
      let ready = await Self.finishes(start, within: Self.helloLANWait, clock: clock)
      guard let self, self.connection != nil, self.clients[connID] != nil else { return }
      if !ready { routerLogger.info("LAN shortcut not ready in time; hello to \(connID) goes without lan") }
      self.replyHello(connID)
    }
  }

  /// Whether a `hello` waits for the LAN endpoint: only from a phone the relay
  /// saw on the Mac's network, and only while the LAN start is in flight.
  nonisolated static func helloWaitsForLAN(sameNetwork: Bool, lanStarting: Bool) -> Bool {
    sameNetwork && lanStarting
  }

  /// Waits for `work` to finish, at most `timeout` on `clock`; true when it
  /// finished in time. Returns at the deadline even though `work` keeps running.
  nonisolated static func finishes(
    _ work: Task<Void, Never>,
    within timeout: Duration,
    clock: any Clock<Duration>
  ) async -> Bool {
    let (outcomes, continuation) = AsyncStream.makeStream(of: Bool.self)
    // Not a task group: a group would wait for `work` even after the deadline.
    let finished = Task {
      await work.value
      continuation.yield(true)
    }
    let deadline = Task {
      try? await clock.sleep(for: timeout)
      continuation.yield(false)
    }
    var outcome = false
    for await first in outcomes {
      outcome = first
      break
    }
    finished.cancel()
    deadline.cancel()
    continuation.finish()
    return outcome
  }

  // MARK: - Terminal stream

  private func attach(connID: String, message: RemoteInboundMessage) {
    guard let raw = message.contentId, let contentID = UUID(uuidString: raw) else {
      replyError(connID, id: message.id, "attach needs a contentId")
      return
    }
    guard source.containsContent(contentID) else {
      replyError(connID, id: message.id, "no such terminal")
      return
    }
    detach(connID: connID)
    let contentKey = raw
    let requestID = message.id
    let socketPath = ZmxRemoteStream.socketPath(contentID: contentID)
    let needsWake = !FileManager.default.fileExists(atPath: socketPath) && source.wake(contentID: contentID)
    let stream = ZmxRemoteStream(socketPath: socketPath)
    // Off the main actor: base64 and framing of every PTY chunk happen here,
    // and the main actor only hands finished frames to the socket, in order.
    let pump = Task.detached { [weak self] in
      for await event in stream.events {
        switch event {
        case .snapshot(let bytes), .output(let bytes):
          let messages = RemoteJSON.outputMessages(contentID: contentKey, bytes: bytes)
          await self?.deliver(connID, messages)
        case .closed(let reason):
          await self?.streamClosed(connID: connID, contentID: contentID, contentKey: contentKey, reason: reason)
        }
      }
    }
    let scrollback = min(max(message.scrollback ?? 500, 0), 10_000)
    // Measures the size first (off the main actor), answers `attached`, starts
    // the stream, then keeps pushing size changes. `attached` always precedes
    // the first `out`, because the stream starts only after it is sent.
    let lifecycle = Task { [weak self] in
      if needsWake { await Self.waitForSocket(at: socketPath) }
      guard let self, self.isCurrent(connID: connID, stream: stream) else { return }
      guard FileManager.default.fileExists(atPath: socketPath) else {
        self.streamClosed(
          connID: connID, contentID: contentID, contentKey: contentKey,
          reason: needsWake ? "the terminal did not start on the Mac" : "session not running")
        return
      }
      var last = await self.measureGrid(contentID: contentID, socketPath: socketPath)
      guard !Task.isCancelled, self.isCurrent(connID: connID, stream: stream) else { return }
      self.reply(
        connID, RemoteAttachedMessage(id: requestID, contentId: contentKey, cols: last.columns, rows: last.rows))
      stream.start(scrollbackRows: scrollback)
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.sizePollInterval)
        guard !Task.isCancelled else { return }
        // A slow or failed PTY read keeps the last size instead of flapping to
        // the view grid or the fallback.
        guard let current = await Self.ptySize(socketPath: socketPath) else { continue }
        if current != last {
          last = current
          self.reply(connID, RemoteSizeMessage(contentId: contentKey, cols: current.columns, rows: current.rows))
        }
      }
    }
    clients[connID] = .some(Attachment(contentID: contentID, stream: stream, pump: pump, sizeWatch: lifecycle))
  }

  /// Hands finished JSON messages to the phone's transport, in order.
  private func deliver(_ connID: String, _ messages: [String]) {
    if let lan = lanSinks[connID] {
      for message in messages { lan(message) }
    } else {
      for message in messages { connection?.send(connID + "\n" + message) }
    }
  }

  private func streamClosed(connID: String, contentID: UUID, contentKey: String, reason: String) {
    reply(connID, RemoteDetachedMessage(contentId: contentKey, reason: reason))
    forgetAttachment(connID: connID, contentID: contentID)
  }

  private func isCurrent(connID: String, stream: ZmxRemoteStream) -> Bool {
    guard case .some(.some(let current)) = clients[connID] else { return false }
    return current.stream === stream
  }

  /// The PTY's real size first (what every program in the session renders at),
  /// then the app's view grid, then a fixed fallback.
  private func measureGrid(contentID: UUID, socketPath: String) async -> (columns: Int, rows: Int) {
    let pty = await Self.ptySize(socketPath: socketPath)
    return pty ?? source.gridSize(contentID: contentID) ?? Self.fallbackGrid
  }

  private static func ptySize(socketPath: String) async -> (columns: Int, rows: Int)? {
    await Task.detached { ZmxRemoteStream.ptySize(socketPath: socketPath) }.value
  }

  /// Polls for a waking session's socket for up to `wakeTimeout`.
  private static func waitForSocket(at path: String) async {
    let deadline = ContinuousClock.now + wakeTimeout
    while ContinuousClock.now < deadline, !FileManager.default.fileExists(atPath: path) {
      try? await Task.sleep(for: .milliseconds(200))
    }
  }

  private func detach(connID: String) {
    guard case .some(.some(let attachment)) = clients[connID] else { return }
    clients[connID] = .some(nil)
    attachment.sizeWatch.cancel()
    attachment.pump.cancel()
    attachment.stream.stop()
  }

  /// Clears an attachment its stream already closed, unless a newer attach replaced it.
  private func forgetAttachment(connID: String, contentID: UUID) {
    guard case .some(.some(let attachment)) = clients[connID], attachment.contentID == contentID else { return }
    attachment.sizeWatch.cancel()
    clients[connID] = .some(nil)
  }

  private func input(connID: String, message: RemoteInboundMessage) {
    guard case .some(.some(let attachment)) = clients[connID],
      let raw = message.contentId, UUID(uuidString: raw) == attachment.contentID
    else {
      replyError(connID, id: message.id, "terminal not attached")
      return
    }
    guard !source.isReadOnly(contentID: attachment.contentID) else {
      replyError(connID, id: message.id, "this terminal is read-only")
      return
    }
    guard let b64 = message.b64, let data = Data(base64Encoded: b64) else {
      replyError(connID, id: message.id, "input needs base64 b64")
      return
    }
    if !attachment.stream.send(Array(data)) {
      replyError(connID, id: message.id, "terminal input failed")
    }
  }

  /// The relay socket dropped: its phones are gone, LAN phones stay.
  private func dropAllClients() {
    for connID in tabNewWaits.keys where lanSinks[connID] == nil {
      cancelTabNewWaits(connID: connID)
    }
    for connID in clients.keys where lanSinks[connID] == nil {
      detach(connID: connID)
      clients[connID] = nil
    }
    sameNetwork.removeAll()
  }

  // MARK: - New tab

  /// Opens a terminal tab in the worktree and answers once the layout lists it
  /// (its content can then be attached), or with an error after `tabNewTimeout`.
  private func newTab(connID: String, message: RemoteInboundMessage) {
    guard let worktreeRaw = message.worktreeId, !worktreeRaw.isEmpty else {
      replyError(connID, id: message.id, "tab.new needs a worktreeId")
      return
    }
    let requestID = message.id
    let grid = RemoteTabNewGrid.resolve(cols: message.cols, rows: message.rows, fallback: Self.newTabGrid)
    switch source.requestNewTab(worktreeID: worktreeRaw) {
    case .failure(let rejection):
      replyError(connID, id: requestID, rejection.message)
    case .success(let tabID):
      let clock = self.clock
      let waitID = UUID()
      let wait = Task { [weak self] in
        let contentID = await Self.poll(every: Self.tabNewPollInterval, within: Self.tabNewTimeout, clock: clock) {
          [weak self] () -> UUID? in
          guard let self, let contentID = self.source.contentID(ofTab: tabID, in: worktreeRaw) else { return nil }
          // Answer only once the grid is sized, so `attached` already reports it.
          let sized = self.source.sizeNewTabGrid(
            contentID: contentID, columns: grid.columns, rows: grid.rows, exact: grid.exact)
          return sized ? contentID : nil
        }
        guard let self, !Task.isCancelled else { return }
        self.tabNewWaits[connID]?[waitID] = nil
        guard self.clients[connID] != nil else { return }
        guard let contentID else {
          routerLogger.warning("tab.new: tab \(tabID) did not appear in \(worktreeRaw)")
          self.replyError(connID, id: requestID, "the new tab did not start on the Mac")
          return
        }
        self.reply(
          connID,
          RemoteTabNewMessage(
            id: requestID, worktreeId: worktreeRaw, tabId: tabID.uuidString, contentId: contentID.uuidString))
      }
      tabNewWaits[connID, default: [:]][waitID] = wait
    }
  }

  private func cancelTabNewWaits(connID: String) {
    guard let waits = tabNewWaits.removeValue(forKey: connID) else { return }
    for wait in waits.values { wait.cancel() }
  }

  /// Checks `probe` now and then every `interval` on `clock` until it gives a
  /// value, or nil once `timeout` passed or the wait is cancelled. The deadline
  /// is one sleep raced against the poller (as in `finishes`), so it fires even
  /// when the poller's interval sleeps fall behind the clock.
  static func poll<Value: Sendable>(
    every interval: Duration,
    within timeout: Duration,
    clock: any Clock<Duration>,
    _ probe: @escaping @MainActor @Sendable () -> Value?
  ) async -> Value? {
    let (outcomes, continuation) = AsyncStream.makeStream(of: Value?.self)
    let poller = Task { @MainActor in
      while !Task.isCancelled {
        if let value = probe() {
          continuation.yield(value)
          return
        }
        try? await clock.sleep(for: interval)
      }
    }
    let deadline = Task {
      try? await clock.sleep(for: timeout)
      continuation.yield(nil)
    }
    var outcome: Value?
    for await first in outcomes {
      outcome = first
      break
    }
    poller.cancel()
    deadline.cancel()
    continuation.finish()
    return outcome
  }

  // MARK: - Suggestions

  private func suggest(connID: String, message: RemoteInboundMessage) {
    guard let raw = message.contentId, let contentID = UUID(uuidString: raw), source.containsContent(contentID) else {
      replyError(connID, id: message.id, "suggest needs a known contentId")
      return
    }
    // One model call per phone at a time; each one can run for 90 s.
    guard suggesting.insert(connID).inserted else {
      replyError(connID, id: message.id, "a suggestion is already running")
      return
    }
    let socketPath = ZmxRemoteStream.socketPath(contentID: contentID)
    let requestID = message.id
    let contextRows = Self.suggestionContextRows
    Task { [weak self] in
      // Off the main actor: the capture, the process launch and its pipes block.
      let outcome = await Task.detached { () -> Result<[String], any Error>? in
        guard
          let captured = ZmxRemoteStream.captureOnce(
            socketPath: socketPath, format: ZmxIPCFrameEncoder.formatPlain, scrollbackRows: contextRows)
        else { return nil }
        // Lossy on purpose: one invalid byte must not empty the whole context.
        let text = String(decoding: captured, as: UTF8.self)  // swiftlint:disable:this optional_data_string_conversion
        do {
          return .success(
            try await RemoteSuggestionRunner.suggest(terminalText: Self.lastLines(text, count: contextRows)))
        } catch {
          return .failure(error)
        }
      }.value
      guard let self else { return }
      self.suggesting.remove(connID)
      switch outcome {
      case nil:
        self.replyError(connID, id: requestID, "could not read the terminal")
      case .success(let suggestions):
        self.reply(connID, RemoteSuggestMessage(id: requestID, contentId: raw, suggestions: suggestions))
      case .failure(let error):
        routerLogger.warning("Suggestion failed: \(error)")
        self.replyError(connID, id: requestID, "suggestion failed: \(error)")
      }
    }
  }

  /// The last `count` lines with trailing blank lines dropped (an idle screen
  /// pads its bottom with empty rows).
  nonisolated static func lastLines(_ text: String, count: Int) -> String {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
      String($0).replacing(/\s+$/, with: "")
    }
    while let last = lines.last, last.isEmpty { lines.removeLast() }
    return lines.suffix(count).joined(separator: "\n")
  }

  // MARK: - Outbound

  private func reply(_ connID: String, _ payload: some Encodable) {
    let json = String(bytes: RemoteJSON.encode(payload), encoding: .utf8) ?? "{}"
    deliver(connID, [json])
  }

  private func replyError(_ connID: String, id: Int?, _ text: String) {
    reply(connID, RemoteErrorMessage(id: id, message: text))
  }
}
