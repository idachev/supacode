import Foundation
import SupacodeSettingsShared

nonisolated private let connectionLogger = SupaLogger("RemoteClient")

nonisolated enum RemoteClientStatus: Equatable, Sendable {
  case idle
  /// No relay socket yet, or waiting to retry.
  case connecting
  /// Connected unbound; the picker decides.
  case choosingHost
  case hostOffline
  case online(RemoteClientPath)
  /// `hello` without every capability the client needs.
  case unsupportedHost
  /// 401, 403, a bad key file: no retry.
  case failed(String)
}

nonisolated enum RemoteTerminalEvent: Equatable, Sendable {
  case attached(cols: Int, rows: Int)
  case out([UInt8])
  case size(cols: Int, rows: Int)
  case detached(reason: String)
}

nonisolated struct RemoteClientRequestError: Error, Equatable {
  enum Kind: Equatable, Sendable { case host, timeout, connectionLost, notConnected }
  let kind: Kind
  let message: String
  let code: String?
}

/// This Mac as a client of another Mac's Supacode (docs/remote-access-protocol.md): the relay
/// socket, the LAN shortcut beside it, request waits, and one gated stream per attached terminal.
///
/// The relay path speaks only on the `hostOnline` false → true edge (`hello`). A `hello` reply with
/// every needed capability brings the relay path up (`list`, `watch`, an `attach` with `keep:true`
/// for every open terminal) and may offer the LAN path; a LAN socket that opens takes the traffic
/// and the relay stays as a pinged fallback. Every terminal frame passes its content's
/// `RemoteStreamGate`, so only the path whose `attached` answered last reaches the terminal.
@MainActor
@Observable
final class RemoteClientConnection {
  static let requiredCaps: Set<String> = [
    "attach.keep", "watch", "layout", "tab.close", "pane.split", "pane.close", "resize.hold",
  ]
  /// The last one repeats.
  static let retryDelays: [Duration] = [.seconds(3), .seconds(6), .seconds(12), .seconds(30)]
  static let lanConnectTimeout: Duration = .milliseconds(2500)
  static let pingInterval: Duration = .seconds(30)
  /// A socket with no frame (`pong` included) for this long is dead.
  static let silenceLimit: Duration = .seconds(75)
  /// A relay upgrade that has not opened by then is given up and retried.
  static let handshakeTimeout: Duration = .seconds(15)
  /// After a failed or closed LAN attempt the relay is asked for `hello` again after this, doubling.
  static let lanRetryFirst: Duration = .seconds(10)
  static let lanRetryLimit: Duration = .seconds(300)

  static let helloText = #"{"t":"hello","v":1}"#
  static let pingText = "ping"
  static let pongText = "pong"
  /// The relay's own error for a message sent while the bound host is offline.
  static let relayHostOffline = "host offline"

  private(set) var status: RemoteClientStatus = .idle
  private(set) var hosts: [RemoteClientHostInfo]?
  /// The relay's last `relay` frame had no `hosts`: an old relay with one Mac, which an unbound
  /// connection shows. False until a `relay` frame came, and after `stop()`.
  private(set) var relayListsNoHosts = false
  private(set) var hostName: String?
  private(set) var list: RemoteClientList?
  /// Grows with every `list` frame, so observers react to a list that arrived.
  private(set) var listRevision = 0

  /// This Mac's own host id, for the picker; the connection itself never uses it.
  let ownHostID: String?
  private let key: RemoteClientKey
  private let sockets: RemoteClientSocketFactory
  private let clock: any Clock<Duration>
  /// Time on `clock` since the connection was made.
  private let elapsed: () -> Duration

  @ObservationIgnored private var running = false
  @ObservationIgnored private var failure: String?
  @ObservationIgnored private var boundHostID: String?
  @ObservationIgnored private var relay: Link?
  /// The LAN socket that opened and carries the traffic.
  @ObservationIgnored private var lan: Link?
  /// The LAN socket still connecting, the address `lanAddressIndex` of `lanOffer`.
  @ObservationIgnored private var lanCandidate: Link?
  @ObservationIgnored private var lanOffer: RemoteClientLAN?
  @ObservationIgnored private var lanAddressIndex = 0
  /// A valid `lan` was acted on since `start`: a later `hello` without it schedules a retry.
  @ObservationIgnored private var lanOffered = false
  @ObservationIgnored private var lanRetryDelay = RemoteClientConnection.lanRetryFirst
  @ObservationIgnored private var lanRetryTask: Task<Void, Never>?
  /// The relay socket's `hello` reply had every capability: the relay path is up.
  @ObservationIgnored private var relayReady = false
  @ObservationIgnored private var unsupported = false
  @ObservationIgnored private var retryIndex = 0
  @ObservationIgnored private var retryTask: Task<Void, Never>?
  @ObservationIgnored private var lastRequestID = 0
  @ObservationIgnored private var pending: [Int: PendingRequest] = [:]
  @ObservationIgnored private var terminals: [String: Terminal] = [:]

  init(key: RemoteClientKey, ownHostID: String?, sockets: RemoteClientSocketFactory, clock: any Clock<Duration>) {
    self.key = key
    self.ownHostID = ownHostID
    self.sockets = sockets
    self.clock = clock
    elapsed = Self.elapsedReader(clock)
  }

  nonisolated deinit {}

  // MARK: - Lifetime

  /// Connects bound to `hostID`, or unbound (nil) to read the host list. Closes any open sockets first.
  func start(hostID: String?) {
    shutDown()
    running = true
    boundHostID = hostID
    connectRelay()
  }

  func stop() {
    shutDown()
  }

  /// Closes both sockets, fails every wait, ends every terminal stream and forgets the host.
  private func shutDown() {
    running = false
    failure = nil
    boundHostID = nil
    closeSockets()
    lanOffered = false
    lanRetryDelay = Self.lanRetryFirst
    retryIndex = 0
    unsupported = false
    for terminal in terminals.values { terminal.continuation.finish() }
    terminals = [:]
    if hostName != nil { hostName = nil }
    if hosts != nil { hosts = nil }
    if relayListsNoHosts { relayListsNoHosts = false }
    if list != nil { list = nil }
    refreshStatus()
  }

  /// A refused key or a bad relay address: everything closes and nothing retries. The terminal
  /// streams stay open until `stop()`, as for a lost connection.
  private func fail(_ message: String) {
    closeSockets()
    running = false
    failure = message
    connectionLogger.warning("Remote client stopped: \(message)")
    refreshStatus()
  }

  private func closeSockets() {
    retryTask?.cancel()
    retryTask = nil
    lanRetryTask?.cancel()
    lanRetryTask = nil
    for link in [relay, lan, lanCandidate].compactMap({ $0 }) { retire(link) }
    relay = nil
    lan = nil
    lanCandidate = nil
    lanOffer = nil
    pathDown(.relay)
    pathDown(.lan)
  }

  // MARK: - Status

  private func refreshStatus() {
    let next = computedStatus
    guard next != status else { return }
    status = next
    connectionLogger.debug("Remote client status: \(next)")
  }

  private var computedStatus: RemoteClientStatus {
    if let failure { return .failed(failure) }
    guard running else { return .idle }
    if unsupported { return .unsupportedHost }
    if lan != nil { return .online(.lan) }
    if relayReady { return .online(.relay) }
    guard let relay, relay.isOpen, relay.sawRelayFrame else { return .connecting }
    if boundHostID == nil, relay.listsHosts { return .choosingHost }
    return relay.hostOnline ? .connecting : .hostOffline
  }

  /// The path new traffic takes: the LAN when it is up, else the relay once its `hello` answered.
  private var activePath: RemoteClientPath? {
    if case .online(let path) = status { path } else { nil }
  }

  // MARK: - Requests

  /// A request with an `id`; resolves with the reply's string fields, or throws the host's error,
  /// a timeout, or `connectionLost` when the path that carried it closes (the wait is not retried).
  func request(
    _ type: String, _ fields: [String: String], ints: [String: Int] = [:], timeout: Duration
  ) async throws -> [String: String] {
    guard let path = activePath else {
      throw RemoteClientRequestError(kind: .notConnected, message: "Not connected to the Mac", code: nil)
    }
    let id = nextRequestID()
    var object: [String: Any] = [:]
    for (name, value) in fields { object[name] = value }
    for (name, value) in ints { object[name] = value }
    object["t"] = type
    object["id"] = id
    return try await withCheckedThrowingContinuation { continuation in
      let timer = after(timeout) { [weak self] in
        self?.finishRequest(
          id, .failure(RemoteClientRequestError(kind: .timeout, message: "The Mac did not answer in time", code: nil)))
      }
      pending[id] = PendingRequest(path: path, continuation: continuation, timeout: timer)
      send(object, on: path)
    }
  }

  private func finishRequest(_ id: Int, _ result: Result<[String: String], RemoteClientRequestError>) {
    guard let request = pending.removeValue(forKey: id) else { return }
    request.timeout.cancel()
    request.continuation.resume(with: result)
  }

  private func nextRequestID() -> Int {
    lastRequestID += 1
    return lastRequestID
  }

  // MARK: - Terminals

  /// Attaches with `keep:true` and yields that terminal's frames, already gated to one path.
  /// The stream ends when `detach(contentID:)` is called or the connection stops.
  func attach(contentID: String, scrollback: Int) -> AsyncStream<RemoteTerminalEvent> {
    let (stream, continuation) = AsyncStream.makeStream(of: RemoteTerminalEvent.self)
    if var terminal = terminals[contentID] {
      // Attaching again restarts the host's stream; the old consumer ends.
      terminal.continuation.finish()
      terminal.continuation = continuation
      terminal.scrollback = scrollback
      terminals[contentID] = terminal
    } else {
      terminals[contentID] = Terminal(continuation: continuation, scrollback: scrollback)
    }
    if let path = activePath { sendAttach(contentID, on: path) }
    return stream
  }

  func detach(contentID: String) {
    guard var terminal = terminals.removeValue(forKey: contentID) else { return }
    terminal.continuation.finish()
    guard let path = terminal.lastAttachPath else { return }
    // Sent at once and in order: a later `attach` of the same content always follows this detach.
    let others = terminal.gate.detachSent(on: path)
    for target in [path] + others { send(["t": "detach", "contentId": contentID], on: target) }
  }

  /// Dropped (returns false) unless the status is `.online`.
  @discardableResult
  func sendInput(contentID: String, bytes: [UInt8]) -> Bool {
    guard let active = activePath, let terminal = terminals[contentID] else { return false }
    let path = terminal.gate.current ?? active
    guard link(for: path) != nil else { return false }
    send(["t": "input", "contentId": contentID, "b64": Data(bytes).base64EncodedString()], on: path)
    return true
  }

  /// The wanted grid of one attached terminal; sent as `resize` with `hold:true` now, and again
  /// after every later `attached` of that terminal, before the old path's `detach`.
  func setWantedGrid(contentID: String, columns: Int, rows: Int) {
    guard terminals[contentID] != nil else { return }
    let grid = Grid(columns: columns, rows: rows)
    terminals[contentID]?.wantedGrid = grid
    // Only on the path whose `attached` answered: before that the grid waits for it (protocol client rule).
    guard activePath != nil, let path = terminals[contentID]?.gate.current else { return }
    sendResize(contentID, grid, on: path)
  }

  private func sendAttach(_ contentID: String, on path: RemoteClientPath) {
    guard var terminal = terminals[contentID] else { return }
    let id = nextRequestID()
    // The gate learns of the attach before its reply can arrive.
    terminal.gate.attachSent(on: path, id: id)
    terminal.attachIDs.insert(id)
    terminal.lastAttachPath = path
    terminals[contentID] = terminal
    send(
      ["t": "attach", "id": id, "contentId": contentID, "scrollback": terminal.scrollback, "keep": true], on: path)
  }

  private func sendResize(_ contentID: String, _ grid: Grid, on path: RemoteClientPath) {
    send(["t": "resize", "contentId": contentID, "cols": grid.columns, "rows": grid.rows, "hold": true], on: path)
  }

  /// One terminal frame through its content's gate. A new path's `attached` first re-sends the
  /// wanted grid on that path, then detaches the old paths (ТР8в), so the hold never lapses.
  private func stream(
    _ contentID: String, _ kind: RemoteStreamGate.Kind, _ event: RemoteTerminalEvent, from path: RemoteClientPath
  ) {
    guard var terminal = terminals[contentID] else { return }
    let verdict = terminal.gate.accept(from: path, kind)
    if case .attached(let id?) = kind { terminal.attachIDs.remove(id) }
    terminals[contentID] = terminal
    if verdict.deliver {
      terminal.continuation.yield(event)
      if case .attached = kind, let grid = terminal.wantedGrid { sendResize(contentID, grid, on: path) }
    }
    for old in verdict.detach { send(["t": "detach", "contentId": contentID], on: old) }
  }

  /// The host refused an `attach` (R10): the terminal's stream ends and the content is forgotten.
  private func attachRefused(_ contentID: String, message: String) {
    terminals[contentID]?.continuation.yield(.detached(reason: message))
    detach(contentID: contentID)
  }

  // MARK: - Sending

  private func link(for path: RemoteClientPath) -> Link? {
    switch path {
    case .relay: relay
    case .lan: lan
    }
  }

  /// JSON from `object` (Swift `Bool`s become JSON booleans) on the path's socket, if it is up.
  private func send(_ object: [String: Any], on path: RemoteClientPath) {
    guard let link = link(for: path), let text = Self.encode(object) else { return }
    link.socket.send(text)
  }

  static func encode(_ object: [String: Any]) -> String? {
    guard
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// `list`, `watch` and an `attach` for every open terminal on a path that just came up.
  private func activate(_ path: RemoteClientPath) {
    send(["t": "list", "id": nextRequestID()], on: path)
    send(["t": "watch", "id": nextRequestID(), "on": true], on: path)
    for contentID in terminals.keys.sorted() { sendAttach(contentID, on: path) }
  }

  /// A path went away (its socket closed, or the relay's host went offline): the host forgot
  /// its attaches there and the waits that travelled on it end.
  private func pathDown(_ path: RemoteClientPath) {
    if path == .relay {
      relayReady = false
      // The next `hello` decides again: the host may come back updated.
      unsupported = false
    }
    for contentID in terminals.keys {
      terminals[contentID]?.gate.closed(path)
      // The host forgot the attach there: a later `detach` must not go out on that path.
      if terminals[contentID]?.lastAttachPath == path { terminals[contentID]?.lastAttachPath = nil }
    }
    let lost = RemoteClientRequestError(kind: .connectionLost, message: "The connection to the Mac was lost", code: nil)
    for (id, request) in pending where request.path == path { finishRequest(id, .failure(lost)) }
  }

  // MARK: - Timing

  /// Runs `action` after `delay` on the clock unless cancelled first.
  private func after(_ delay: Duration, _ action: @escaping @MainActor () -> Void) -> Task<Void, Never> {
    let clock = self.clock
    return Task {
      do { try await clock.sleep(for: delay) } catch { return }
      action()
    }
  }

  private static func elapsedReader<C: Clock>(_ clock: C) -> () -> Duration where C.Duration == Duration {
    let start = clock.now
    return { start.duration(to: clock.now) }
  }
}

// MARK: - Sockets

extension RemoteClientConnection {
  /// One socket and what the connection keeps about it.
  @MainActor
  fileprivate final class Link {
    enum Role { case relay, lanCandidate, lan }

    var role: Role
    let socket: any RemoteClientSocket
    var isOpen = false
    /// Retired: its later events are ignored.
    var isFinished = false
    /// When its last frame arrived, on the connection's clock.
    var lastFrame: Duration = .zero
    /// Relay only: the last `hostOnline`, for the false → true edge (РФ3).
    var hostOnline = false
    var sawRelayFrame = false
    /// Relay only: the last `relay` frame carried `hosts` (a multi-host relay).
    var listsHosts = false
    var tasks: [Task<Void, Never>] = []

    init(role: Role, socket: any RemoteClientSocket) {
      self.role = role
      self.socket = socket
    }

    nonisolated deinit {}

    var path: RemoteClientPath? {
      switch role {
      case .relay: .relay
      case .lan: .lan
      case .lanCandidate: nil
      }
    }
  }

  fileprivate struct Grid: Equatable {
    let columns: Int
    let rows: Int
  }

  fileprivate struct Terminal {
    var gate = RemoteStreamGate()
    var continuation: AsyncStream<RemoteTerminalEvent>.Continuation
    var scrollback: Int
    var wantedGrid: Grid?
    /// Attaches sent and not yet answered by an `attached`.
    var attachIDs: Set<Int> = []
    var lastAttachPath: RemoteClientPath?
  }

  fileprivate struct PendingRequest {
    let path: RemoteClientPath
    let continuation: CheckedContinuation<[String: String], any Error>
    let timeout: Task<Void, Never>
  }

  private func connectRelay() {
    guard running, relay == nil else { return }
    guard let url = key.clientURL(hostID: boundHostID) else {
      fail("The relay address in the key file is not valid")
      return
    }
    let link = Link(role: .relay, socket: sockets.relay(url, key.key))
    relay = link
    listen(to: link)
    link.tasks.append(
      after(Self.handshakeTimeout) { [weak self, weak link] in
        guard let self, let link, !link.isOpen else { return }
        socketClosed(link, reason: "no answer")
      })
    refreshStatus()
  }

  private func listen(to link: Link) {
    let events = link.socket.events
    link.tasks.append(
      Task { [weak self, weak link] in
        for await event in events {
          guard let self, let link else { return }
          handle(event, from: link)
        }
      })
  }

  /// A `ping` every `pingInterval`; a socket silent for `silenceLimit` is closed instead.
  private func startKeepalive(_ link: Link) {
    let clock = self.clock
    link.tasks.append(
      Task { [weak self, weak link] in
        while true {
          do { try await clock.sleep(for: Self.pingInterval) } catch { return }
          guard let self, let link, !link.isFinished else { return }
          if elapsed() - link.lastFrame > Self.silenceLimit {
            socketClosed(link, reason: "no answer")
            return
          }
          link.socket.send(Self.pingText)
        }
      })
  }

  /// Stops the link's tasks and closes its socket; its own `.closed` is ignored afterwards.
  private func retire(_ link: Link) {
    link.isFinished = true
    for task in link.tasks { task.cancel() }
    link.tasks = []
    link.socket.close()
  }

  private func handle(_ event: RemoteClientSocketEvent, from link: Link) {
    guard !link.isFinished else { return }
    switch event {
    case .opened:
      opened(link)
    case .text(let text):
      link.lastFrame = elapsed()
      guard text != Self.pongText else { return }
      let frame: RemoteClientFrame
      switch RemoteClientFrame.read(text) {
      case .success(let read):
        frame = read
      case .failure(let unreadable):
        // Its type and where decoding stopped only: never the frame's content.
        connectionLogger.warning(
          "Remote client dropped a \(unreadable.type ?? "untyped") frame it cannot read: \(unreadable.reason)")
        return
      }
      guard let path = link.path else { return }
      receive(frame, on: path, from: link)
    case .closed(let reason):
      socketClosed(link, reason: reason)
    }
  }

  private func opened(_ link: Link) {
    link.isOpen = true
    link.lastFrame = elapsed()
    startKeepalive(link)
    switch link.role {
    case .relay: refreshStatus()
    case .lanCandidate: adoptLAN(link)
    case .lan: break
    }
  }

  private func socketClosed(_ link: Link, reason: String) {
    guard !link.isFinished else { return }
    retire(link)
    switch link.role {
    case .relay: relayClosed(link, reason: reason)
    case .lanCandidate: lanAttemptFailed(link)
    case .lan: lanClosed(link)
    }
  }

  /// Only the relay's plain `401` / `403` means the key is refused; anything else retries.
  private func relayClosed(_ link: Link, reason: String) {
    guard relay === link else { return }
    relay = nil
    pathDown(.relay)
    if reason == "401" || reason == "403" {
      fail("The relay refused the client key (HTTP \(reason))")
      return
    }
    let delay = Self.retryDelays[min(retryIndex, Self.retryDelays.count - 1)]
    retryIndex += 1
    connectionLogger.debug("Remote client relay closed; retry \(retryIndex)")
    retryTask = after(delay) { [weak self] in self?.connectRelay() }
    refreshStatus()
  }

  // MARK: - Frames

  private func receive(_ frame: RemoteClientFrame, on path: RemoteClientPath, from link: Link) {
    switch frame {
    case .relay(let update):
      if path == .relay { relayStatusChanged(update, on: link) }
    case .hello(let hello):
      helloReceived(hello, on: path)
    case .list(let newList):
      list = newList
      listRevision += 1
      if let id = newList.id { finishRequest(id, .success([:])) }
    case .reply(_, let id, let fields):
      if let id { finishRequest(id, .success(fields)) }
    case .error(let id, let message, let code, _):
      errorReceived(id: id, message: message, code: code, on: path)
    case .attached(let id, let contentID, let cols, let rows):
      stream(contentID, .attached(id: id), .attached(cols: cols, rows: rows), from: path)
    case .out(let contentID, let bytes):
      stream(contentID, .out, .out(bytes), from: path)
    case .size(let contentID, let cols, let rows):
      stream(contentID, .size, .size(cols: cols, rows: rows), from: path)
    case .detached(let contentID, let reason):
      stream(contentID, .detached, .detached(reason: reason), from: path)
    }
  }

  private func relayStatusChanged(_ update: RemoteClientRelayStatus, on link: Link) {
    if hosts != update.hosts { hosts = update.hosts }
    if relayListsNoHosts != (update.hosts == nil) { relayListsNoHosts = update.hosts == nil }
    if !link.sawRelayFrame {
      // The relay answered this socket: the next drop starts the backoff over.
      link.sawRelayFrame = true
      retryIndex = 0
    }
    link.listsHosts = update.hosts != nil
    // Unbound against a multi-host relay: only the list is read, nothing is sent.
    if boundHostID == nil, update.hosts != nil {
      refreshStatus()
      return
    }
    let wasOnline = link.hostOnline
    link.hostOnline = update.hostOnline
    if update.hostOnline, !wasOnline {
      link.socket.send(Self.helloText)
    } else if !update.hostOnline, wasOnline {
      pathDown(.relay)
    }
    refreshStatus()
  }

  private func helloReceived(_ hello: RemoteClientHello, on path: RemoteClientPath) {
    if let name = hello.host, name != hostName { hostName = name }
    // `lan` in the LAN socket's own `hello` means nothing new.
    guard path == .relay else { return }
    if !relayReady {
      guard Self.requiredCaps.isSubset(of: hello.caps) else {
        unsupported = true
        refreshStatus()
        return
      }
      unsupported = false
      relayReady = true
      if lan == nil { activate(.relay) }
    }
    offerLAN(hello)
    refreshStatus()
  }

  private func errorReceived(id: Int?, message: String, code: String?, on path: RemoteClientPath) {
    guard let id else { return }
    if pending[id] != nil {
      finishRequest(id, .failure(RemoteClientRequestError(kind: .host, message: message, code: code)))
    } else if let contentID = terminals.first(where: { $0.value.attachIDs.contains(id) })?.key {
      if path == .relay, code == nil, message == Self.relayHostOffline {
        // The relay's own answer, not the host's: the path is down, not the terminal. The
        // `hostOnline` false frame closes the relay in the gate, and the next online edge re-attaches it.
        terminals[contentID]?.attachIDs.remove(id)
      } else {
        attachRefused(contentID, message: message)
      }
    }
  }

  // MARK: - LAN

  private func offerLAN(_ hello: RemoteClientHello) {
    if let bound = boundHostID, let other = hello.hostId, other != bound { return }
    guard let offer = hello.lan else {
      if lanOffered, lan == nil, lanCandidate == nil { scheduleLANRetry() }
      return
    }
    guard RemoteLANTrust.fpMacValid(clientKey: key.key, fp: offer.fp, fpMac: offer.fpMac) else {
      connectionLogger.warning("Remote client refused a LAN offer with a wrong fingerprint MAC")
      return
    }
    guard lan == nil, lanCandidate == nil else { return }
    lanOffered = true
    lanRetryTask?.cancel()
    lanRetryTask = nil
    lanOffer = offer
    tryLAN(at: 0)
  }

  /// One address at a time, each raced against `lanConnectTimeout`.
  private func tryLAN(at index: Int) {
    guard let offer = lanOffer, index < offer.addrs.count else {
      lanOffer = nil
      lanCandidate = nil
      connectionLogger.debug("Remote client LAN attempt failed")
      scheduleLANRetry()
      return
    }
    lanAddressIndex = index
    let socket = sockets.lan(offer.addrs[index], offer.port, offer.fp, key.key)
    let link = Link(role: .lanCandidate, socket: socket)
    lanCandidate = link
    listen(to: link)
    link.tasks.append(
      after(Self.lanConnectTimeout) { [weak self, weak link] in
        guard let self, let link, !link.isOpen else { return }
        socketClosed(link, reason: "timeout")
      })
  }

  private func lanAttemptFailed(_ link: Link) {
    guard lanCandidate === link else { return }
    lanCandidate = nil
    tryLAN(at: lanAddressIndex + 1)
  }

  private func adoptLAN(_ link: Link) {
    guard lanCandidate === link else { return }
    lanCandidate = nil
    lanOffer = nil
    link.role = .lan
    lan = link
    lanRetryDelay = Self.lanRetryFirst
    lanRetryTask?.cancel()
    lanRetryTask = nil
    connectionLogger.debug("Remote client LAN path is up")
    link.socket.send(Self.helloText)
    activate(.lan)
    // Pushed lists now come over the LAN; the relay stops sending them (R7).
    if relayReady { send(["t": "watch", "id": nextRequestID(), "on": false], on: .relay) }
    refreshStatus()
  }

  /// Back to the relay: it watches again and every open terminal re-attaches there.
  private func lanClosed(_ link: Link) {
    guard lan === link else { return }
    lan = nil
    pathDown(.lan)
    connectionLogger.debug("Remote client LAN path closed")
    if relayReady { activate(.relay) }
    scheduleLANRetry()
    refreshStatus()
  }

  /// Asks the relay for `hello` again later; its reply carries `lan` while the Mac is near.
  private func scheduleLANRetry() {
    guard running else { return }
    lanRetryTask?.cancel()
    let wait = lanRetryDelay
    lanRetryDelay = min(wait * 2, Self.lanRetryLimit)
    lanRetryTask = after(wait) { [weak self] in
      guard let self, lan == nil, lanCandidate == nil, let relay, relay.hostOnline else { return }
      relay.socket.send(Self.helloText)
    }
  }
}
