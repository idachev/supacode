import AppKit
import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

nonisolated private let routerLogger = SupaLogger("RemoteAccess")

/// Answers the phones behind the relay: `hello`, `list`, terminal
/// `attach` / `detach` / `input` / `resize`, `tab.new`, `worktree.new` and `suggest`
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
  /// How often a `resize` re-reads the session PTY until it has the new grid,
  /// for up to `resizeConfirmTimeout` in all. The PTY takes the grid
  /// asynchronously (Ghostty's IO thread, then the `zmx attach` leader, then
  /// the zmx daemon), so the reply waits for the size the stream really has.
  static let resizeSettle: Duration = .milliseconds(150)
  static let resizeConfirmTimeout: Duration = .seconds(3)
  /// How long a `resize` of a terminal without a live surface waits for the
  /// woken surface's cell metrics before it answers `resize_failed`; the same
  /// bound as an `attach` waiting for a woken session (`wakeTimeout`).
  static let resizeReadyTimeout: Duration = .seconds(6)
  static let resizeRetryInterval: Duration = .milliseconds(100)
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
    let contentKey: String
    let socketPath: String
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
  /// `worktree.new` waits in flight per phone, cancelled with the phone's
  /// connection (the creation itself goes on).
  private var worktreeNewWaits: [String: [UUID: Task<Void, Never>]] = [:]
  /// The `resize` in flight per terminal (waking it, then reading the PTY
  /// size); a newer `resize` of that terminal from any phone, or the
  /// requester's detach or end, cancels it (last request wins).
  private var resizeWaits = RemoteResizeWaits()
  /// The grid each attached phone last got (`attached` or `size`), shared by
  /// the poll and a resize's early check so neither sends the same size twice.
  private var sentGrids: [String: SentGrid] = [:]
  private struct SentGrid: Equatable {
    let columns: Int
    let rows: Int
  }
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
  /// The app build every `hello` reports (`RemoteHelloMessage.appLabel`); nil omits the field.
  private let appLabel: String?
  /// The missing-hardware-UUID warning goes out once per process, not per start.
  private static var warnedMissingHostID = false

  init(
    source: RemoteSnapshotSource,
    hostName: String,
    hostID: String?,
    appLabel: String? = RemoteHelloMessage.currentAppLabel(),
    clock: any Clock<Duration> = ContinuousClock()
  ) {
    self.source = source
    self.hostName = hostName
    self.hostID = hostID
    self.appLabel = appLabel
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
    cancelWorktreeNewWaits(connID: connID)
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
      connectionOpened(connID, sameNetwork: message.sameNetwork == true)
    case "conn.close":
      cancelTabNewWaits(connID: connID)
      cancelWorktreeNewWaits(connID: connID)
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
      detachRequested(connID: connID, message: message)
    case "input":
      input(connID: connID, message: message)
    case "suggest":
      suggest(connID: connID, message: message)
    case "tab.new":
      newTab(connID: connID, message: message)
    case "worktree.new":
      newWorktree(connID: connID, message: message)
    case "resize":
      resize(connID: connID, message: message)
    default:
      replyError(connID, id: message.id, "unknown message type: \(message.t)")
    }
  }

  /// The relay announced a phone (`conn.open`), possibly on the Mac's network.
  private func connectionOpened(_ connID: String, sameNetwork onMacNetwork: Bool) {
    if clients[connID] == nil { clients[connID] = .some(nil) }
    if onMacNetwork { sameNetwork.insert(connID) } else { sameNetwork.remove(connID) }
  }

  // MARK: - Hello

  private func replyHello(_ connID: String) {
    reply(connID, helloMessage(for: connID))
  }

  /// The `hello` answer for one phone: name, id, app build and, for a same-network phone, `lan`.
  func helloMessage(for connID: String) -> RemoteHelloMessage {
    RemoteHelloMessage(host: hostName, hostId: hostID, lan: lanCandidate(for: connID), app: appLabel)
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
      let first = await self.measureGrid(contentID: contentID, socketPath: socketPath)
      guard !Task.isCancelled, self.isCurrent(connID: connID, stream: stream) else { return }
      self.sentGrids[connID] = SentGrid(columns: first.columns, rows: first.rows)
      self.reply(
        connID, RemoteAttachedMessage(id: requestID, contentId: contentKey, cols: first.columns, rows: first.rows))
      stream.start(scrollbackRows: scrollback)
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.sizePollInterval)
        guard !Task.isCancelled else { return }
        await self.sendSizeIfChanged(connID: connID, stream: stream)
      }
    }
    clients[connID] = .some(
      Attachment(
        contentID: contentID, contentKey: contentKey, socketPath: socketPath,
        stream: stream, pump: pump, sizeWatch: lifecycle))
  }

  /// Reads the PTY grid and sends `size` when it differs from the one the
  /// phone last got. A slow or failed PTY read keeps the last size instead of
  /// flapping to the view grid or the fallback.
  private func sendSizeIfChanged(connID: String, stream: ZmxRemoteStream) async {
    guard case .some(.some(let attachment)) = clients[connID], attachment.stream === stream else { return }
    guard let current = await Self.ptySize(socketPath: attachment.socketPath) else { return }
    // The phone may have detached or attached elsewhere during the read.
    guard isCurrent(connID: connID, stream: stream) else { return }
    let grid = SentGrid(columns: current.columns, rows: current.rows)
    guard sentGrids[connID] != grid else { return }
    sentGrids[connID] = grid
    reply(connID, RemoteSizeMessage(contentId: attachment.contentKey, cols: grid.columns, rows: grid.rows))
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

  /// A late detach for a tab the phone already left must not drop the newer
  /// attachment: honor the contentId when it is given.
  private func detachRequested(connID: String, message: RemoteInboundMessage) {
    if let raw = message.contentId, case .some(.some(let current)) = clients[connID],
      UUID(uuidString: raw) != current.contentID
    {
      return
    }
    detach(connID: connID)
  }

  private func detach(connID: String) {
    cancelResizeWait(connID: connID)
    guard case .some(.some(let attachment)) = clients[connID] else { return }
    clients[connID] = .some(nil)
    sentGrids[connID] = nil
    attachment.sizeWatch.cancel()
    attachment.pump.cancel()
    attachment.stream.stop()
  }

  /// Clears an attachment its stream already closed, unless a newer attach replaced it.
  private func forgetAttachment(connID: String, contentID: UUID) {
    guard case .some(.some(let attachment)) = clients[connID], attachment.contentID == contentID else { return }
    attachment.sizeWatch.cancel()
    clients[connID] = .some(nil)
    sentGrids[connID] = nil
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

  /// Sets the attached terminal's grid to the client's size and answers with
  /// the size the session PTY really has (`ptySize`, what the remote stream
  /// renders at), never the app's view grid:
  /// - the PTY takes the size: `size` to the requester (even when it already
  ///   had that size) and to every other phone attached there whose size changed;
  /// - the PTY keeps another size: that `size` plus an `error` (`resize_failed`);
  /// - the size cannot be applied or read: an `error` (`resize_failed`).
  /// A terminal without a live surface (hibernated, or not started since
  /// launch) is woken off-window and sized once its cell metrics exist
  /// (`settleResize`). A request for another content or with a bad size is
  /// ignored and logged.
  private func resize(connID: String, message: RemoteInboundMessage) {
    var attached: UUID?
    if case .some(.some(let attachment)) = clients[connID] { attached = attachment.contentID }
    switch RemoteResizeRequest.resolve(message, attached: attached) {
    case .failure(.notAttached):
      routerLogger.info("resize from \(connID) ignored: content \(message.contentId ?? "nil") is not attached")
    case .failure(.invalidSize):
      routerLogger.info("resize from \(connID) ignored: cols and rows must both be integers")
    case .success(let request):
      // Before the new size is applied, so an older wait never retries its size over it.
      resizeWaits.cancel(contentID: request.contentID)
      let source = self.source
      let clock = self.clock
      let requestID = message.id
      let socketPath = ZmxRemoteStream.socketPath(contentID: request.contentID)
      let attempt: @MainActor @Sendable () -> RemoteResizeAttempt = {
        source.resizeGrid(contentID: request.contentID, columns: request.columns, rows: request.rows)
      }
      // In this turn, so a live terminal's grid changes before the next message.
      let first = attempt()
      let token = UUID()
      let wait = Task { [weak self] in
        await Self.runResize(
          request: request, first: first, clock: clock,
          wake: { source.wake(contentID: request.contentID) }, attempt: attempt,
          readSize: { await Self.ptySize(socketPath: socketPath) },
          finish: { outcome in
            guard let self else { return }
            self.resizeWaits.finished(contentID: request.contentID, token: token)
            self.finishResize(connID: connID, request: request, requestID: requestID, outcome: outcome)
          })
      }
      resizeWaits.start(contentID: request.contentID, connID: connID, token: token, task: wait)
    }
  }

  /// Settles one `resize` (`settleResize`), confirms the size on the session
  /// PTY (`confirmResize`) and hands the outcome to `finish`, unless a newer
  /// `resize` of that terminal or the requester's detach cancelled the wait
  /// meanwhile: a cancelled request gets no reply and no redraw.
  static func runResize(
    request: RemoteResizeRequest,
    first: RemoteResizeAttempt,
    clock: any Clock<Duration>,
    wake: @MainActor () -> Bool,
    attempt: @escaping @MainActor @Sendable () -> RemoteResizeAttempt,
    readSize: @escaping @Sendable () async -> (columns: Int, rows: Int)?,
    finish: @MainActor (Result<RemoteResizeConfirmation, RemoteResizeResult.Failure>) -> Void
  ) async {
    let settled = await settleResize(first: first, clock: clock, wake: wake, attempt: attempt)
    let outcome: Result<RemoteResizeConfirmation, RemoteResizeResult.Failure>
    switch settled {
    case .failed(let failure):
      outcome = .failure(failure)
    case .applied, .unchanged:
      // Also for an unchanged grid: the PTY may still be taking an earlier resize.
      let confirmation = await confirmResize(
        grid: (columns: request.columns, rows: request.rows),
        interval: resizeSettle, within: resizeConfirmTimeout, clock: clock, readSize: readSize)
      outcome = .success(confirmation)
    }
    guard !Task.isCancelled else { return }
    finish(outcome)
  }

  /// Ctrl+L (form feed): the redraw key of shells and TUIs (Claude Code, vim, htop).
  nonisolated static let redrawKey: [UInt8] = [0x0C]

  /// The input a settled `resize` writes to the terminal (ЗД9): Ctrl+L once
  /// the PTY confirmed the requested size, also when the grid already had it
  /// (the client asks for a resize when the screen looks wrong, so it doubles
  /// as a redraw); nothing for a `resize_failed` outcome or a read-only terminal.
  nonisolated static func redrawInput(
    for outcome: Result<RemoteResizeConfirmation, RemoteResizeResult.Failure>,
    isReadOnly: Bool
  ) -> [UInt8] {
    guard !isReadOnly, case .success(.matched) = outcome else { return [] }
    return redrawKey
  }

  /// Answers a settled `resize`, unless the phone left that terminal meanwhile,
  /// then writes the redraw key (`redrawInput(for:isReadOnly:)`) once, as an
  /// `input` would: through the requester's stream, or the first other open
  /// stream of that terminal when the requester's is not open (`writeOnce`).
  private func finishResize(
    connID: String,
    request: RemoteResizeRequest,
    requestID: Int?,
    outcome: Result<RemoteResizeConfirmation, RemoteResizeResult.Failure>
  ) {
    guard case .some(.some(let attachment)) = clients[connID], attachment.contentID == request.contentID else {
      return
    }
    let replies = Self.resizeReplies(
      for: outcome, request: request, contentKey: attachment.contentKey, requestID: requestID)
    for reply in replies {
      switch reply {
      case .size(let size):
        let grid = SentGrid(columns: size.cols, rows: size.rows)
        // Every phone on that terminal gets it, even when it already had the
        // size: the requester waits for it, and another phone's resize may
        // have been cancelled by this one (the poll's dedupe is bypassed).
        for (other, entry) in clients {
          guard case .some(let shown) = entry, shown.contentID == request.contentID else { continue }
          sentGrids[other] = grid
          self.reply(other, RemoteSizeMessage(contentId: shown.contentKey, cols: grid.columns, rows: grid.rows))
        }
      case .error(let error):
        routerLogger.info("resize from \(connID) failed: \(error.message)")
        self.reply(connID, error)
      }
    }
    let redraw = Self.redrawInput(for: outcome, isReadOnly: source.isReadOnly(contentID: request.contentID))
    guard !redraw.isEmpty else { return }
    // The requester's stream may not be open yet (an `attach` still measuring
    // the grid) or already closed; any other phone's stream on that terminal
    // reaches the same zmx session.
    let others = clients.compactMap { other, entry -> (String, ZmxRemoteStream)? in
      guard other != connID, case .some(let shown) = entry, shown.contentID == request.contentID else { return nil }
      return (other, shown.stream)
    }
    .sorted { $0.0 < $1.0 }
    .map(\.1)
    let senders = ([attachment.stream] + others).map { stream in { (bytes: [UInt8]) in stream.send(bytes) } }
    if !Self.writeOnce(redraw, through: senders) {
      routerLogger.info("resize from \(connID): no open stream took the redraw input")
    }
  }

  /// Writes `bytes` through the first of `senders` that takes them (each is a
  /// stream's `send`), so the terminal gets them once. False when none did.
  nonisolated static func writeOnce(_ bytes: [UInt8], through senders: [([UInt8]) -> Bool]) -> Bool {
    senders.contains { send in send(bytes) }
  }

  /// One frame a settled `resize` sends.
  nonisolated enum ResizeReply: Equatable, Sendable {
    /// The session PTY's size: to every phone attached to that content.
    case size(RemoteSizeMessage)
    /// To the requester only.
    case error(RemoteErrorMessage)
  }

  /// The frames for a settled `resize`, in order.
  nonisolated static func resizeReplies(
    for outcome: Result<RemoteResizeConfirmation, RemoteResizeResult.Failure>,
    request: RemoteResizeRequest,
    contentKey: String,
    requestID: Int?
  ) -> [ResizeReply] {
    func failed(_ failure: RemoteResizeResult.Failure) -> ResizeReply {
      .error(
        RemoteErrorMessage(
          id: requestID, message: failure.message, code: RemoteResizeResult.errorCode, contentId: contentKey))
    }
    switch outcome {
    case .success(.matched):
      return [.size(RemoteSizeMessage(contentId: contentKey, cols: request.columns, rows: request.rows))]
    case .success(.mismatch(let columns, let rows)):
      return [.size(RemoteSizeMessage(contentId: contentKey, cols: columns, rows: rows)), failed(.sessionKeptItsSize)]
    case .success(.unreadable):
      return [failed(.sizeUnreadable)]
    case .failure(let failure):
      return [failed(failure)]
    }
  }

  /// Reads the session PTY until it has `grid`: now, then every `interval` on
  /// `clock`, for at most `timeout` in all (a slow read counts against it).
  /// `.mismatch` carries the last size read; `.unreadable` means no read succeeded.
  nonisolated static func confirmResize(
    grid: (columns: Int, rows: Int),
    interval: Duration,
    within timeout: Duration,
    clock: any Clock<Duration>,
    readSize: @escaping @Sendable () async -> (columns: Int, rows: Int)?
  ) async -> RemoteResizeConfirmation {
    let (events, continuation) = AsyncStream.makeStream(of: ResizeConfirmEvent.self)
    // Not a loop with its own deadline check: a read may block past the deadline.
    let reader = Task {
      while !Task.isCancelled {
        let size = await readSize()
        continuation.yield(.read(columns: size?.columns, rows: size?.rows))
        try? await clock.sleep(for: interval)
      }
    }
    let deadline = Task {
      try? await clock.sleep(for: timeout)
      continuation.yield(.deadline)
    }
    var matched = false
    var last: (columns: Int, rows: Int)?
    for await event in events {
      guard case .read(let columns, let rows) = event else { break }
      guard let columns, let rows else { continue }
      if columns == grid.columns, rows == grid.rows {
        matched = true
        break
      }
      last = (columns, rows)
    }
    reader.cancel()
    deadline.cancel()
    continuation.finish()
    if matched { return .matched }
    guard let last else { return .unreadable }
    return .mismatch(columns: last.columns, rows: last.rows)
  }

  nonisolated enum ResizeConfirmEvent: Sendable {
    /// One PTY read; nil sizes when it failed.
    case read(columns: Int?, rows: Int?)
    case deadline
  }

  /// Finishes a `resize` whose first try (`first`) found no live surface or no
  /// cell metrics yet: wakes the terminal off-window when it has no surface
  /// (the Mac does not show it, so the new surface takes the size as its start
  /// size, as a phone-opened tab does), then retries `attempt` every
  /// `resizeRetryInterval` on `clock` for up to `resizeReadyTimeout`.
  static func settleResize(
    first: RemoteResizeAttempt,
    clock: any Clock<Duration>,
    wake: @MainActor () -> Bool,
    attempt: @escaping @MainActor @Sendable () -> RemoteResizeAttempt
  ) async -> RemoteResizeResult {
    switch first {
    case .applied:
      return .applied
    case .unchanged:
      return .unchanged
    case .notReady:
      break
    case .noSurface, .failedToStart:
      // False when no worktree lists the content any more.
      guard wake() else { return .failed(.contentGone) }
    }
    let settled = await poll(every: resizeRetryInterval, within: resizeReadyTimeout, clock: clock) {
      () -> RemoteResizeResult? in
      switch attempt() {
      case .applied: return .applied
      case .unchanged: return .unchanged
      // The wake ran synchronously, so this is its own failure, not a stale one.
      case .failedToStart: return .failed(.wakeFailed)
      case .notReady, .noSurface: return nil
      }
    }
    return settled ?? .failed(.notReady)
  }

  private func cancelResizeWait(connID: String) {
    resizeWaits.cancel(connID: connID)
  }

  /// The relay socket dropped: its phones are gone, LAN phones stay.
  private func dropAllClients() {
    for connID in tabNewWaits.keys where lanSinks[connID] == nil {
      cancelTabNewWaits(connID: connID)
    }
    for connID in worktreeNewWaits.keys where lanSinks[connID] == nil {
      cancelWorktreeNewWaits(connID: connID)
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
    switch source.requestNewTab(worktreeID: worktreeRaw, startGrid: grid.startGrid) {
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
          // A tab started at the grid (`startGrid`) passes at once; one with no
          // live terminal to measure it on is sized here, after its PTY started.
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

  // MARK: - New worktree

  /// Creates a worktree in a repository the way the Mac's own New Worktree
  /// button does, and answers once the app reported the outcome and (for a
  /// created worktree) its first terminal tab is in the layout, or without
  /// the tab after `worktreeNewTabTimeout` (`runWorktreeNew`). Refusals the
  /// router can decide (bad fields, unknown repository, duplicate) are answered at once.
  private func newWorktree(connID: String, message: RemoteInboundMessage) {
    let requestID = message.id
    let request: RemoteWorktreeNewRequest
    switch RemoteWorktreeNewRequest.resolve(message) {
    case .failure(let rejection):
      replyError(connID, id: requestID, rejection.message, code: rejection.code)
      return
    case .success(let resolved):
      request = resolved
    }
    // The app's `.creating` entry is the guard: it outlives this phone's wait.
    guard !source.isWorktreeCreationInFlight(repositoryID: request.repositoryID, name: request.name) else {
      let busy = RemoteWorktreeNewRejection.busy
      replyError(connID, id: requestID, busy.message, code: busy.code)
      return
    }
    let start: RemoteWorktreeNewStart
    switch source.requestNewWorktree(repositoryID: request.repositoryID, name: request.name) {
    case .failure(let rejection):
      replyError(connID, id: requestID, rejection.message, code: rejection.code)
      return
    case .success(let started):
      start = started
    }
    let grid = RemoteTabNewGrid.resolve(cols: message.cols, rows: message.rows, fallback: Self.newTabGrid)
    let source = self.source
    let clock = self.clock
    let probes = source.worktreeNewProbes(pendingID: start.pendingID, grid: grid)
    let waitID = UUID()
    let wait = Task { [weak self] in
      // Consumes or abandons the app's entry on every exit, a cancelled wait included.
      let outcome = await Self.awaitWorktreeNew(
        isSSH: start.isSSH, clock: clock, probes: probes,
        consume: { source.consumeWorktreeCreation(pendingID: start.pendingID) },
        abandon: { source.abandonWorktreeCreation(pendingID: start.pendingID) })
      guard let self else { return }
      self.worktreeNewWaits[connID]?[waitID] = nil
      guard self.clients[connID] != nil,
        let reply = Self.worktreeNewReply(for: outcome, repositoryID: request.repositoryID, requestID: requestID)
      else { return }
      switch reply {
      case .worktree(let created): self.reply(connID, created)
      case .error(let error): self.reply(connID, error)
      }
    }
    worktreeNewWaits[connID, default: [:]][waitID] = wait
  }

  /// Stops this phone's `worktree.new` waits; they send nothing. The creations
  /// go on, and each keeps its `worktree_busy` guard until its outcome settles.
  private func cancelWorktreeNewWaits(connID: String) {
    guard let waits = worktreeNewWaits.removeValue(forKey: connID) else { return }
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

  private func replyError(_ connID: String, id: Int?, _ text: String, code: String? = nil) {
    reply(connID, RemoteErrorMessage(id: id, message: text, code: code))
  }
}
