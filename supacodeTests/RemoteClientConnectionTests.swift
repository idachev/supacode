import Clocks
import ConcurrencyExtras
import Foundation
import Synchronization
import Testing

@testable import supacode

/// A socket the test drives: it records what the connection sends (only while open, as the real
/// sockets do) and emits the events the test gives it. `close()` yields `.closed` once.
nonisolated final class FakeClientSocket: RemoteClientSocket {
  private struct State {
    var isOpen = false
    var isClosed = false
    var sent: [String] = []
  }

  let label: String
  let events: AsyncStream<RemoteClientSocketEvent>
  private let continuation: AsyncStream<RemoteClientSocketEvent>.Continuation
  private let state = Mutex(State())
  private let journal: FakeClientSockets.Journal

  init(label: String, journal: FakeClientSockets.Journal) {
    self.label = label
    self.journal = journal
    (events, continuation) = AsyncStream.makeStream()
  }

  var sent: [String] { state.withLock { $0.sent } }
  /// The `t` of every sent frame, the keepalive left out.
  var types: [String] { sent.filter { $0 != "ping" }.compactMap(FakeClientSockets.frameType) }
  var pings: Int { sent.count(where: { $0 == "ping" }) }
  var isClosed: Bool { state.withLock { $0.isClosed } }

  func open() {
    let first = state.withLock { current -> Bool in
      guard !current.isOpen, !current.isClosed else { return false }
      current.isOpen = true
      return true
    }
    if first { continuation.yield(.opened) }
  }

  func receive(_ text: String) {
    continuation.yield(.text(text))
  }

  /// The other end closed (or the connect failed) with `reason`.
  func drop(reason: String) {
    finish(reason: reason)
  }

  func send(_ text: String) {
    let accepted = state.withLock { current -> Bool in
      guard current.isOpen, !current.isClosed else { return false }
      current.sent.append(text)
      return true
    }
    if accepted { journal.append(label, text) }
  }

  func close() {
    finish(reason: "closed")
  }

  private func finish(reason: String) {
    let first = state.withLock { current -> Bool in
      guard !current.isClosed else { return false }
      current.isClosed = true
      return true
    }
    guard first else { return }
    continuation.yield(.closed(reason: reason))
    continuation.finish()
  }
}

/// Hands out fake sockets and records how they were asked for.
nonisolated final class FakeClientSockets: Sendable {
  nonisolated struct LANCall: Equatable, Sendable {
    let addr: String
    let port: Int
    let pin: String
    let key: String
  }

  /// Every sent frame of every socket, in order, as `<label> <text>`.
  nonisolated final class Journal: Sendable {
    private let entries = Mutex<[String]>([])

    func append(_ label: String, _ text: String) {
      entries.withLock { $0.append("\(label) \(text)") }
    }

    var all: [String] { entries.withLock { $0 } }
  }

  private struct State {
    var relays: [FakeClientSocket] = []
    var urls: [URL] = []
    var keys: [String] = []
    var lans: [FakeClientSocket] = []
    var lanCalls: [LANCall] = []
  }

  let journal = Journal()
  private let state = Mutex(State())

  var relays: [FakeClientSocket] { state.withLock { $0.relays } }
  var urls: [URL] { state.withLock { $0.urls } }
  var keys: [String] { state.withLock { $0.keys } }
  var lans: [FakeClientSocket] { state.withLock { $0.lans } }
  var lanCalls: [LANCall] { state.withLock { $0.lanCalls } }

  var factory: RemoteClientSocketFactory {
    RemoteClientSocketFactory(
      relay: { url, key in self.makeRelay(url: url, key: key) },
      lan: { addr, port, pin, key in self.makeLAN(LANCall(addr: addr, port: port, pin: pin, key: key)) }
    )
  }

  private func makeRelay(url: URL, key: String) -> FakeClientSocket {
    let socket = FakeClientSocket(label: "relay", journal: journal)
    state.withLock {
      $0.relays.append(socket)
      $0.urls.append(url)
      $0.keys.append(key)
    }
    return socket
  }

  private func makeLAN(_ call: LANCall) -> FakeClientSocket {
    let socket = FakeClientSocket(label: "lan", journal: journal)
    state.withLock {
      $0.lans.append(socket)
      $0.lanCalls.append(call)
    }
    return socket
  }

  static func object(_ frame: String) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(frame.utf8))) as? [String: Any]
  }

  static func frameType(_ frame: String) -> String? {
    object(frame)?["t"] as? String
  }
}

/// Collects one terminal's events.
@MainActor
final class RemoteTerminalEventLog {
  private(set) var events: [RemoteTerminalEvent] = []
  private(set) var ended = false
  private var task: Task<Void, Never>?

  init(_ stream: AsyncStream<RemoteTerminalEvent>) {
    task = Task { [weak self] in
      for await event in stream { self?.events.append(event) }
      self?.ended = true
    }
  }

  nonisolated deinit {}
}

/// The outcome of one `request` started in the background.
@MainActor
final class RemoteRequestOutcome {
  var result: Result<[String: String], RemoteClientRequestError>?

  var errorKind: RemoteClientRequestError.Kind? {
    if case .failure(let error) = result { error.kind } else { nil }
  }

  nonisolated deinit {}
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RemoteClientConnectionTests {
  static let key = RemoteClientKey(relayHost: "relay.example.com", key: RemoteClientGateTests.key)
  static let caps = RemoteClientConnection.requiredCaps.sorted()
  static let lanAddrs = ["10.0.0.5"]

  struct Rig {
    let connection: RemoteClientConnection
    let sockets: FakeClientSockets
    let clock: TestClock<Duration>

    /// The newest relay socket.
    var relay: FakeClientSocket { sockets.relays[sockets.relays.count - 1] }
    /// The newest LAN socket.
    var lan: FakeClientSocket { sockets.lans[sockets.lans.count - 1] }
  }

  private func rig(hostID: String? = "h1") -> Rig {
    let clock = TestClock<Duration>()
    let sockets = FakeClientSockets()
    let connection = RemoteClientConnection(key: Self.key, ownHostID: "me", sockets: sockets.factory, clock: clock)
    connection.start(hostID: hostID)
    return Rig(connection: connection, sockets: sockets, clock: clock)
  }

  // MARK: Frames

  static func json(_ object: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    return String(data: data, encoding: .utf8) ?? ""
  }

  static func relayFrame(online: Bool, name: String = "Office Mac") -> String {
    json([
      "t": "relay", "hostOnline": online, "host": "h1",
      "hosts": [["id": "h1", "name": name, "online": online]],
    ])
  }

  static func helloFrame(
    caps: [String] = caps, hostId: String? = "h1", lan addrs: [String]? = nil,
    fpMac: String = RemoteClientGateTests.fpMac
  ) -> String {
    var object: [String: Any] = ["t": "hello", "v": 1, "host": "Office Mac", "caps": caps]
    if let hostId { object["hostId"] = hostId }
    if let addrs {
      object["lan"] = ["addrs": addrs, "port": 49731, "fp": RemoteClientGateTests.fpHex, "fpMac": fpMac]
    }
    return json(object)
  }

  static func attached(_ contentID: String, id: Int, cols: Int = 120, rows: Int = 40) -> String {
    json(["t": "attached", "id": id, "contentId": contentID, "cols": cols, "rows": rows])
  }

  static func out(_ contentID: String, _ text: String) -> String {
    json(["t": "out", "contentId": contentID, "b64": Data(text.utf8).base64EncodedString()])
  }

  /// The sent frames other than the keepalive, decoded.
  static func frames(_ socket: FakeClientSocket) -> [[String: Any]] {
    socket.sent.filter { $0 != "ping" }.compactMap(FakeClientSockets.object)
  }

  /// The raw text of the last sent frame of `type` (and `contentID`, when given).
  static func lastText(_ socket: FakeClientSocket, _ type: String, contentID: String? = nil) -> String {
    socket.sent.last { text in
      guard let object = FakeClientSockets.object(text), object["t"] as? String == type else { return false }
      return contentID == nil || object["contentId"] as? String == contentID
    } ?? ""
  }

  static func lastID(_ socket: FakeClientSocket, _ type: String, contentID: String? = nil) -> Int {
    FakeClientSockets.object(lastText(socket, type, contentID: contentID))?["id"] as? Int ?? -1
  }

  /// The journal from `mark` on as `<label> <t> <contentId>`, the keepalive left out.
  static func trace(_ rig: Rig, from mark: Int) -> [String] {
    rig.sockets.journal.all.dropFirst(mark).compactMap { entry in
      let parts = entry.split(separator: " ", maxSplits: 1).map(String.init)
      guard parts.count == 2, let object = FakeClientSockets.object(parts[1]) else { return nil }
      let type = object["t"] as? String ?? "?"
      let content = object["contentId"] as? String
      return [parts[0], type, content].compactMap { $0 }.joined(separator: " ")
    }
  }

  // MARK: Helpers

  private func settle(_ condition: () -> Bool) async -> Bool {
    await RemoteRouterTestSupport.settle(condition)
  }

  private func stepUntil(_ rig: Rig, _ condition: () -> Bool, within limit: Duration) async -> Bool {
    await RemoteRouterTestSupport.step(rig.clock, until: condition, within: limit)
  }

  /// Crosses `span` in small steps, then steps until `condition` holds within `window`.
  private func cross(
    _ rig: Rig, _ span: Duration, thenUntil condition: () -> Bool, within window: Duration = .seconds(1)
  ) async -> Bool {
    await RemoteRouterTestSupport.step(rig.clock, by: span, increment: .milliseconds(500))
    return await RemoteRouterTestSupport.step(rig.clock, until: condition, within: window)
  }

  /// Opens the relay, brings the host online and answers `hello` with `hello`.
  @discardableResult
  private func online(_ rig: Rig, hello: String = helloFrame()) async -> FakeClientSocket {
    let relay = rig.relay
    relay.open()
    relay.receive(Self.relayFrame(online: true))
    #expect(await settle { relay.types.last == "hello" })
    relay.receive(hello)
    #expect(await settle { rig.connection.status == .online(.relay) })
    return relay
  }

  /// From the relay path: a `hello` reply with `lan`, then the LAN socket opens.
  @discardableResult
  private func lanUp(_ rig: Rig, relay: FakeClientSocket) async -> FakeClientSocket {
    let before = rig.sockets.lans.count
    relay.receive(Self.helloFrame(lan: Self.lanAddrs))
    #expect(await settle { rig.sockets.lans.count == before + 1 })
    let lan = rig.lan
    lan.open()
    #expect(await settle { rig.connection.status == .online(.lan) })
    return lan
  }

  private func launch(
    _ connection: RemoteClientConnection, _ type: String, _ fields: [String: String] = ["worktreeId": "w1"],
    ints: [String: Int] = [:], timeout: Duration = .seconds(30)
  ) -> RemoteRequestOutcome {
    let outcome = RemoteRequestOutcome()
    Task {
      do {
        outcome.result = .success(try await connection.request(type, fields, ints: ints, timeout: timeout))
      } catch let error as RemoteClientRequestError {
        outcome.result = .failure(error)
      } catch {
        Issue.record("unexpected error type")
      }
    }
    return outcome
  }

  // MARK: Relay and hello

  @Test func nothingIsSentBeforeTheHostIsOnline() async {
    let rig = rig()
    #expect(rig.sockets.urls.map(\.absoluteString) == ["wss://relay.example.com/client?host=h1"])
    #expect(rig.sockets.keys == [Self.key.key])
    let relay = rig.relay
    relay.open()
    relay.receive(Self.relayFrame(online: false))
    #expect(await settle { rig.connection.status == .hostOffline })
    #expect(relay.sent.isEmpty)
    #expect(rig.connection.hosts?.map(\.id) == ["h1"])
  }

  @Test func theOnlineEdgeSendsHelloOnce() async {
    let rig = rig()
    let relay = rig.relay
    relay.open()
    relay.receive(Self.relayFrame(online: false))
    relay.receive(Self.relayFrame(online: true))
    #expect(await settle { relay.types == ["hello"] })
    #expect(relay.sent == [#"{"t":"hello","v":1}"#])
    relay.receive(Self.relayFrame(online: true, name: "Renamed"))
    #expect(await settle { rig.connection.hosts?.first?.name == "Renamed" })
    #expect(relay.types == ["hello"])
  }

  @Test func helloWithEveryCapAsksForListAndWatch() async {
    let rig = rig()
    let relay = await online(rig)
    #expect(relay.types == ["hello", "list", "watch"])
    #expect(Self.lastText(relay, "watch").contains(#""on":true"#))
    #expect(rig.connection.hostName == "Office Mac")
  }

  @Test func aHostWithoutACapIsUnsupported() async {
    let rig = rig()
    let relay = rig.relay
    relay.open()
    relay.receive(Self.relayFrame(online: true))
    #expect(await settle { relay.types == ["hello"] })
    _ = rig.connection.attach(contentID: "c1", scrollback: 500)
    relay.receive(Self.helloFrame(caps: Self.caps.filter { $0 != "resize.hold" }, lan: Self.lanAddrs))
    #expect(await settle { rig.connection.status == .unsupportedHost })
    #expect(relay.types == ["hello"])
    #expect(rig.sockets.lanCalls.isEmpty)
    // The host leaving the relay is reported as offline, not as still unsupported.
    relay.receive(Self.relayFrame(online: false))
    #expect(await settle { rig.connection.status == .hostOffline })
  }

  @Test func anUnboundStartOnlyReadsTheHostList() async {
    let rig = rig(hostID: nil)
    #expect(rig.sockets.urls.map(\.absoluteString) == ["wss://relay.example.com/client"])
    let relay = rig.relay
    relay.open()
    relay.receive(#"{"t":"relay","hostOnline":false,"hosts":[{"id":"h1","name":"Office Mac","online":true}]}"#)
    #expect(await settle { rig.connection.status == .choosingHost })
    #expect(rig.connection.hosts == [RemoteClientHostInfo(id: "h1", name: "Office Mac", online: true)])
    #expect(relay.sent.isEmpty)
  }

  /// R9: an old relay sends no `hosts`; unbound then means single host.
  @Test func anUnboundStartAgainstAnOldRelayActsAsSingleHost() async {
    let rig = rig(hostID: nil)
    let relay = rig.relay
    relay.open()
    relay.receive(#"{"t":"relay","hostOnline":false}"#)
    #expect(await settle { rig.connection.status == .hostOffline })
    relay.receive(#"{"t":"relay","hostOnline":true}"#)
    #expect(await settle { relay.types == ["hello"] })
    #expect(rig.connection.hosts == nil)
    relay.receive(Self.helloFrame(hostId: nil))
    #expect(await settle { rig.connection.status == .online(.relay) })
    #expect(relay.types == ["hello", "list", "watch"])
  }

  /// F3: whether the relay lists its Macs is known only from its frames; an old relay's one Mac is
  /// what every unbound window would show, so the windows ask before opening another.
  @Test func theRelaySaysWhetherItListsItsMacs() async {
    let rig = rig(hostID: "h1")
    #expect(!rig.connection.relayListsNoHosts)
    let relay = rig.relay
    relay.open()
    relay.receive(#"{"t":"relay","hostOnline":true}"#)
    #expect(await settle { rig.connection.relayListsNoHosts })
    relay.receive(Self.relayFrame(online: true))
    #expect(await settle { !rig.connection.relayListsNoHosts })
    relay.receive(#"{"t":"relay","hostOnline":true}"#)
    #expect(await settle { rig.connection.relayListsNoHosts })
    rig.connection.stop()
    #expect(!rig.connection.relayListsNoHosts)
  }

  /// The relay's host going offline ends the waits on it; its return brings hello, list and the attaches again.
  @Test func theHostComingBackReattaches() async {
    let rig = rig()
    let relay = await online(rig)
    _ = rig.connection.attach(contentID: "c1", scrollback: 500)
    let outcome = launch(rig.connection, "worktree.delete")
    #expect(await settle { relay.types.last == "worktree.delete" })
    relay.receive(Self.relayFrame(online: false))
    #expect(await settle { rig.connection.status == .hostOffline && outcome.result != nil })
    #expect(outcome.errorKind == .connectionLost)
    relay.receive(Self.relayFrame(online: true))
    #expect(await settle { relay.types.last == "hello" })
    relay.receive(Self.helloFrame())
    #expect(await settle { rig.connection.status == .online(.relay) })
    #expect(relay.types == ["hello", "list", "watch", "attach", "worktree.delete", "hello", "list", "watch", "attach"])
  }

  // MARK: Requests

  @Test func aRequestResolvesWithItsReply() async throws {
    let rig = rig()
    let relay = await online(rig)
    let outcome = launch(rig.connection, "tab.new", ints: ["cols": 80, "rows": 24])
    #expect(await settle { relay.types.last == "tab.new" })
    let text = Self.lastText(relay, "tab.new")
    #expect(text.contains(#""worktreeId":"w1""#))
    #expect(text.contains(#""cols":80"#))
    let id = Self.lastID(relay, "tab.new")
    relay.receive(Self.json(["t": "tab.new", "id": id, "tabId": "t9", "contentId": "c9"]))
    #expect(await settle { outcome.result != nil })
    #expect(outcome.result == .success(["tabId": "t9", "contentId": "c9"]))
  }

  /// R6: `worktrees.refresh` is answered by a `list` with the request's id.
  @Test func aRefreshResolvesWithItsList() async {
    let rig = rig()
    let relay = await online(rig)
    let before = rig.connection.listRevision
    let outcome = launch(rig.connection, "worktrees.refresh", [:], timeout: .seconds(70))
    #expect(await settle { relay.types.last == "worktrees.refresh" })
    let id = Self.lastID(relay, "worktrees.refresh")
    relay.receive(Self.json(["t": "list", "id": id, "repos": [["id": "r1", "name": "supacode"]]]))
    #expect(await settle { outcome.result != nil })
    #expect(outcome.result == .success([:]))
    #expect(rig.connection.list?.repos.map(\.id) == ["r1"])
    #expect(rig.connection.listRevision == before + 1)
    relay.receive(#"{"t":"list","id":null,"repos":[]}"#)
    #expect(await settle { rig.connection.listRevision == before + 2 })
    #expect(rig.connection.list?.repos.isEmpty == true)
  }

  @Test func aHostErrorThrowsWithItsCode() async {
    let rig = rig()
    let relay = await online(rig)
    let outcome = launch(rig.connection, "worktree.delete")
    #expect(await settle { relay.types.last == "worktree.delete" })
    let id = Self.lastID(relay, "worktree.delete")
    relay.receive(
      Self.json(["t": "error", "id": id, "message": "the worktree has changes", "code": "worktree_dirty"]))
    #expect(await settle { outcome.result != nil })
    #expect(
      outcome.result
        == .failure(RemoteClientRequestError(kind: .host, message: "the worktree has changes", code: "worktree_dirty")))
  }

  @Test func aRequestTimesOut() async {
    let rig = rig()
    let relay = await online(rig)
    let outcome = launch(rig.connection, "worktrees.refresh", [:], timeout: .seconds(70))
    #expect(await settle { relay.types.last == "worktrees.refresh" })
    #expect(await cross(rig, .seconds(69), thenUntil: { outcome.result != nil }, within: .seconds(2)))
    #expect(outcome.errorKind == .timeout)
  }

  @Test func aRequestWhileNotOnlineIsRefused() async {
    let rig = rig()
    let outcome = launch(rig.connection, "tab.new")
    #expect(await settle { outcome.result != nil })
    #expect(outcome.errorKind == .notConnected)
  }

  @Test func aLostConnectionEndsTheWait() async {
    let rig = rig()
    let relay = await online(rig)
    let outcome = launch(rig.connection, "worktree.delete")
    #expect(await settle { relay.types.last == "worktree.delete" })
    relay.drop(reason: "connection lost")
    #expect(await settle { outcome.result != nil })
    #expect(outcome.errorKind == .connectionLost)
    #expect(rig.connection.status == .connecting)
    #expect(await stepUntil(rig, { rig.sockets.relays.count == 2 }, within: .seconds(4)))
    let next = await online(rig)
    #expect(next.types == ["hello", "list", "watch"])
  }

  // MARK: Terminals

  @Test func attachSendsKeepAndYieldsGatedFrames() async {
    let rig = rig()
    let relay = await online(rig)
    let log = RemoteTerminalEventLog(rig.connection.attach(contentID: "c1", scrollback: 2000))
    let text = Self.lastText(relay, "attach")
    #expect(text.contains(#""keep":true"#))
    #expect(text.contains(#""scrollback":2000"#))
    #expect(text.contains(#""contentId":"c1""#))
    relay.receive(Self.out("c1", "early"))
    relay.receive(Self.attached("c1", id: Self.lastID(relay, "attach")))
    relay.receive(Self.out("c1", "hi"))
    relay.receive(Self.json(["t": "size", "contentId": "c1", "cols": 100, "rows": 30]))
    relay.receive(Self.out("c2", "other"))
    relay.receive(Self.json(["t": "detached", "contentId": "c1", "reason": "session ended"]))
    let expected: [RemoteTerminalEvent] = [
      .attached(cols: 120, rows: 40), .out(Array("hi".utf8)), .size(cols: 100, rows: 30),
      .detached(reason: "session ended"),
    ]
    #expect(await settle { log.events == expected })
  }

  @Test func detachEndsTheStreamAndTellsTheHost() async {
    let rig = rig()
    let relay = await online(rig)
    let log = RemoteTerminalEventLog(rig.connection.attach(contentID: "c1", scrollback: 500))
    relay.receive(Self.attached("c1", id: Self.lastID(relay, "attach")))
    #expect(await settle { log.events.count == 1 })
    rig.connection.detach(contentID: "c1")
    #expect(await settle { log.ended })
    #expect(relay.types.last == "detach")
    #expect(Self.lastText(relay, "detach").contains(#""contentId":"c1""#))
  }

  /// R10: an `error` answering an `attach` ends that terminal's stream.
  @Test func anAttachErrorEndsThatTerminalsStream() async {
    let rig = rig()
    let relay = await online(rig)
    let log = RemoteTerminalEventLog(rig.connection.attach(contentID: "c1", scrollback: 500))
    let id = Self.lastID(relay, "attach")
    relay.receive(
      Self.json([
        "t": "error", "id": id, "code": "attach_limit", "contentId": "c1", "message": "too many attached terminals",
      ]))
    #expect(await settle { log.ended })
    #expect(log.events == [.detached(reason: "too many attached terminals")])
    #expect(!rig.connection.sendInput(contentID: "c1", bytes: [0x61]))
  }

  @Test func inputIsDroppedWhileOffline() async {
    let rig = rig()
    let relay = rig.relay
    relay.open()
    relay.receive(Self.relayFrame(online: false))
    _ = rig.connection.attach(contentID: "c1", scrollback: 500)
    #expect(await settle { rig.connection.status == .hostOffline })
    #expect(!rig.connection.sendInput(contentID: "c1", bytes: [0x61]))
    #expect(relay.sent.isEmpty)
    relay.receive(Self.relayFrame(online: true))
    #expect(await settle { relay.types == ["hello"] })
    relay.receive(Self.helloFrame())
    #expect(await settle { relay.types == ["hello", "list", "watch", "attach"] })
    relay.receive(Self.attached("c1", id: Self.lastID(relay, "attach")))
    #expect(await settle { rig.connection.sendInput(contentID: "c1", bytes: [0x61]) })
    #expect(Self.lastText(relay, "input").contains(#""b64":"YQ==""#))
  }

  /// РФ5: typing while there is no connection is never sent later and never queued.
  @Test func inputTypedWhileOfflineIsNeverSentLater() async {
    let rig = rig()
    let relay = await online(rig)
    _ = rig.connection.attach(contentID: "c1", scrollback: 500)
    #expect(await settle { relay.types.last == "attach" })
    relay.receive(Self.attached("c1", id: Self.lastID(relay, "attach")))
    #expect(await settle { rig.connection.sendInput(contentID: "c1", bytes: [0x61]) })
    #expect(Self.frames(relay).count(where: { $0["t"] as? String == "input" }) == 1)

    relay.drop(reason: "connection lost")
    #expect(await settle { rig.connection.status == .connecting })
    for byte: UInt8 in [0x62, 0x63, 0x64] {
      #expect(!rig.connection.sendInput(contentID: "c1", bytes: [byte]))
    }

    #expect(await cross(rig, .milliseconds(2500), thenUntil: { rig.sockets.relays.count == 2 }))
    let second = rig.relay
    second.open()
    second.receive(Self.relayFrame(online: true))
    #expect(await settle { second.types.last == "hello" })
    second.receive(Self.helloFrame())
    #expect(await settle { second.types == ["hello", "list", "watch", "attach"] })
    second.receive(Self.attached("c1", id: Self.lastID(second, "attach")))
    #expect(await settle { rig.connection.status == .online(.relay) })
    #expect(!second.sent.contains { $0.contains(#""t":"input""#) })
    // Only the keystroke typed while online ever left, on the first socket.
    #expect(Self.frames(relay).filter { $0["t"] as? String == "input" }.count == 1)
  }

  // MARK: LAN

  @Test func aValidLanOfferOpensTheLanPath() async {
    let rig = rig()
    _ = rig.connection.attach(contentID: "c1", scrollback: 500)
    let relay = await online(rig, hello: Self.helloFrame(lan: Self.lanAddrs))
    #expect(
      rig.sockets.lanCalls
        == [.init(addr: "10.0.0.5", port: 49731, pin: RemoteClientGateTests.fpHex, key: Self.key.key)])
    let lan = rig.lan
    lan.open()
    #expect(await settle { rig.connection.status == .online(.lan) })
    #expect(lan.types == ["hello", "list", "watch", "attach"])
    #expect(Self.lastText(lan, "attach").contains(#""keep":true"#))
    #expect(Self.lastText(lan, "watch").contains(#""on":true"#))
    // R7: the relay stops pushing lists while the LAN carries them.
    #expect(relay.types == ["hello", "list", "watch", "attach", "watch"])
    #expect(Self.lastText(relay, "watch").contains(#""on":false"#))
  }

  @Test func aBadFpMacMakesNoLanAttempt() async {
    let rig = rig()
    let badMac = String(repeating: "0", count: 64)
    await online(rig, hello: Self.helloFrame(lan: Self.lanAddrs, fpMac: badMac))
    #expect(rig.sockets.lanCalls.isEmpty)
  }

  @Test func aHelloFromAnotherHostMakesNoLanAttempt() async {
    let rig = rig()
    await online(rig, hello: Self.helloFrame(hostId: "other", lan: Self.lanAddrs))
    #expect(rig.sockets.lanCalls.isEmpty)
  }

  @Test func aSlowLanAddressGivesWayToTheNext() async {
    let rig = rig()
    await online(rig, hello: Self.helloFrame(lan: ["10.0.0.4", "10.0.0.5", "10.0.0.6"]))
    #expect(rig.sockets.lanCalls.map(\.addr) == ["10.0.0.4"])
    rig.lan.drop(reason: "connection failed")
    #expect(await settle { rig.sockets.lanCalls.count == 2 })
    #expect(
      await cross(
        rig, RemoteClientConnection.lanConnectTimeout - .milliseconds(500),
        thenUntil: { rig.sockets.lanCalls.count == 3 }))
    #expect(rig.sockets.lans[1].isClosed)
    #expect(rig.sockets.lanCalls.map(\.addr) == ["10.0.0.4", "10.0.0.5", "10.0.0.6"])
    rig.lan.open()
    #expect(await settle { rig.connection.status == .online(.lan) })
  }

  /// ТР8в, РФ4: the new path's `resize` with `hold:true` goes out before the old path's `detach`.
  @Test func aPathSwitchResizesBeforeItDetaches() async {
    let rig = rig()
    let relay = await online(rig)
    let one = RemoteTerminalEventLog(rig.connection.attach(contentID: "c1", scrollback: 500))
    let two = RemoteTerminalEventLog(rig.connection.attach(contentID: "c2", scrollback: 500))
    relay.receive(Self.attached("c1", id: Self.lastID(relay, "attach", contentID: "c1")))
    relay.receive(Self.attached("c2", id: Self.lastID(relay, "attach", contentID: "c2")))
    #expect(await settle { one.events.count == 1 && two.events.count == 1 })
    rig.connection.setWantedGrid(contentID: "c1", columns: 100, rows: 30)
    rig.connection.setWantedGrid(contentID: "c2", columns: 80, rows: 24)
    #expect(Self.lastText(relay, "resize", contentID: "c1").contains(#""hold":true"#))
    #expect(Self.lastText(relay, "resize", contentID: "c2").contains(#""cols":80"#))

    let lan = await lanUp(rig, relay: relay)
    #expect(lan.types == ["hello", "list", "watch", "attach", "attach"])
    for (content, log, cols) in [("c1", one, 100), ("c2", two, 80)] {
      let mark = rig.sockets.journal.all.count
      lan.receive(Self.attached(content, id: Self.lastID(lan, "attach", contentID: content), cols: cols))
      #expect(await settle { Self.trace(rig, from: mark).count == 2 })
      #expect(Self.trace(rig, from: mark) == ["lan resize \(content)", "relay detach \(content)"])
      let resize = Self.lastText(lan, "resize", contentID: content)
      #expect(resize.contains(#""hold":true"#))
      #expect(resize.contains("\"cols\":\(cols)"))
      relay.receive(Self.out(content, "late"))
      lan.receive(Self.out(content, "new"))
      #expect(await settle { log.events.last == .out(Array("new".utf8)) })
      #expect(!log.events.contains(.out(Array("late".utf8))))
    }
  }

  @Test func theLanClosingFallsBackToTheRelayAndReattaches() async {
    let rig = rig()
    let relay = await online(rig)
    _ = rig.connection.attach(contentID: "c1", scrollback: 500)
    let lan = await lanUp(rig, relay: relay)
    lan.receive(Self.attached("c1", id: Self.lastID(lan, "attach")))
    #expect(await settle { relay.types.last == "detach" })
    let mark = relay.types.count
    lan.drop(reason: "connection lost")
    #expect(await settle { rig.connection.status == .online(.relay) })
    #expect(Array(relay.types.dropFirst(mark)) == ["list", "watch", "attach"])
    // R7: the relay watches again.
    #expect(Self.lastText(relay, "watch").contains(#""on":true"#))
    #expect(Self.lastText(relay, "attach").contains(#""keep":true"#))
  }

  /// A pushed `list` whose only change is a tab's title (the web client typed into it).
  static func titledList(_ title: String) -> String {
    json([
      "t": "list", "id": NSNull(),
      "repos": [["id": "r", "worktrees": [["id": "w", "tabs": [["id": "t1", "contentId": "c1", "title": title]]]]]],
    ])
  }

  private func tabTitle(_ rig: Rig) -> String? {
    rig.connection.list?.repos.first?.worktrees.first?.tabs.first?.title
  }

  /// ЖП13 (L3): lists the host pushes reach `list` on whichever path is up: the LAN once it is
  /// adopted (it watches there, the relay stops), the relay again after the LAN closed (it watches
  /// again), and a LAN adopted a second time.
  @Test func pushedListsArriveOnTheLanTheRelayAndALanAdoptedAgain() async {
    let rig = rig()
    let relay = await online(rig)
    let lan = await lanUp(rig, relay: relay)
    #expect(Self.lastText(lan, "watch").contains(#""on":true"#))
    #expect(Self.lastText(relay, "watch").contains(#""on":false"#))
    var revision = rig.connection.listRevision
    lan.receive(Self.titledList("vim"))
    #expect(await settle { tabTitle(rig) == "vim" })
    #expect(rig.connection.listRevision == revision + 1)
    lan.receive(Self.titledList("htop"))
    #expect(await settle { tabTitle(rig) == "htop" })

    // The LAN closes: the relay watches again and its pushes arrive.
    let mark = relay.types.count
    lan.drop(reason: "connection lost")
    #expect(await settle { rig.connection.status == .online(.relay) })
    #expect(Array(relay.types.dropFirst(mark)) == ["list", "watch"])
    #expect(Self.lastText(relay, "watch").contains(#""on":true"#))
    revision = rig.connection.listRevision
    relay.receive(Self.titledList("zsh"))
    #expect(await settle { tabTitle(rig) == "zsh" })
    #expect(rig.connection.listRevision == revision + 1)

    // The LAN retry asks for `hello`; its offer brings a second LAN, which watches in turn.
    #expect(await stepUntil(rig, { relay.types.last == "hello" }, within: .seconds(11)))
    let second = await lanUp(rig, relay: relay)
    #expect(second !== lan)
    #expect(second.types == ["hello", "list", "watch"])
    #expect(Self.lastText(second, "watch").contains(#""on":true"#))
    #expect(Self.lastText(relay, "watch").contains(#""on":false"#))
    second.receive(Self.titledList("make"))
    #expect(await settle { tabTitle(rig) == "make" })
  }

  @Test func theRelayDroppingKeepsTheLanPath() async {
    let rig = rig()
    let relay = await online(rig)
    let lan = await lanUp(rig, relay: relay)
    let outcome = launch(rig.connection, "tab.new")
    #expect(await settle { lan.types.last == "tab.new" })
    relay.drop(reason: "connection lost")
    #expect(await stepUntil(rig, { rig.sockets.relays.count == 2 }, within: .seconds(4)))
    #expect(rig.connection.status == .online(.lan))
    #expect(outcome.result == nil)
    let next = rig.relay
    next.open()
    next.receive(Self.relayFrame(online: true))
    #expect(await settle { next.types == ["hello"] })
    next.receive(Self.helloFrame(lan: Self.lanAddrs))
    _ = await settle { false }
    #expect(next.types == ["hello"])
    #expect(rig.sockets.lans.count == 1)
    #expect(rig.connection.status == .online(.lan))
  }

  /// R11: a closed LAN asks the relay for `hello` again after 10 s, then 20 s after a failed attempt;
  /// a `hello` reply on a relay path already online only re-checks `lan`.
  @Test func aClosedLanAsksForHelloAgainAfterTenSecondsThenTwenty() async {
    let rig = rig()
    let relay = await online(rig)
    let lan = await lanUp(rig, relay: relay)
    lan.drop(reason: "connection lost")
    #expect(await settle { rig.connection.status == .online(.relay) })
    let hellos = { relay.types.count(where: { $0 == "hello" }) }
    #expect(hellos() == 1)
    #expect(await cross(rig, .milliseconds(9500), thenUntil: { hellos() == 2 }))
    let mark = relay.types.count
    relay.receive(Self.helloFrame(lan: Self.lanAddrs))
    #expect(await settle { rig.sockets.lans.count == 2 })
    #expect(relay.types.count == mark)
    rig.lan.drop(reason: "connection failed")
    #expect(await cross(rig, .milliseconds(19500), thenUntil: { hellos() == 3 }))
    relay.receive(Self.helloFrame())
    _ = await settle { false }
    #expect(relay.types.count == mark + 1)
    #expect(rig.sockets.lans.count == 2)
  }

  // MARK: Reconnects and keepalive

  @Test func reconnectsWaitThreeSecondsAndMore() async {
    let rig = rig()
    rig.relay.drop(reason: "connection failed")
    let delays: [Duration] = [.seconds(3), .seconds(6), .seconds(12), .seconds(30), .seconds(30)]
    for (index, delay) in delays.enumerated() {
      await RemoteRouterTestSupport.step(rig.clock, by: delay - .milliseconds(500), increment: .milliseconds(500))
      #expect(rig.sockets.relays.count == index + 1)
      #expect(
        await RemoteRouterTestSupport.step(
          rig.clock, until: { rig.sockets.relays.count == index + 2 }, within: .milliseconds(1500)))
      #expect(rig.connection.status == .connecting)
      rig.relay.drop(reason: "connection failed")
    }
  }

  @Test func aRelayFrameResetsTheBackoff() async {
    let rig = rig()
    rig.relay.drop(reason: "connection failed")
    #expect(await cross(rig, .milliseconds(2500), thenUntil: { rig.sockets.relays.count == 2 }))
    rig.relay.drop(reason: "connection failed")
    #expect(await cross(rig, .milliseconds(5500), thenUntil: { rig.sockets.relays.count == 3 }))
    rig.relay.open()
    rig.relay.receive(Self.relayFrame(online: false))
    #expect(await settle { rig.connection.status == .hostOffline })
    rig.relay.drop(reason: "closed by relay")
    #expect(await cross(rig, .milliseconds(2500), thenUntil: { rig.sockets.relays.count == 4 }))
  }

  @Test(arguments: ["401", "403"])
  func aRefusedKeyDoesNotRetry(status: String) async {
    let rig = rig()
    rig.relay.drop(reason: status)
    #expect(await settle { if case .failed = rig.connection.status { true } else { false } })
    await RemoteRouterTestSupport.step(rig.clock, by: .seconds(60), increment: .seconds(1))
    #expect(rig.sockets.relays.count == 1)
  }

  /// R8: a ping every 30 s; a socket silent for 75 s is closed and replaced.
  @Test func aSilentRelayIsClosedAndReplaced() async {
    let rig = rig()
    let relay = await online(rig)
    #expect(await cross(rig, .milliseconds(29500), thenUntil: { relay.pings == 1 }))
    #expect(await cross(rig, .milliseconds(29500), thenUntil: { relay.pings == 2 }))
    relay.receive("pong")
    #expect(await cross(rig, .milliseconds(29500), thenUntil: { relay.pings == 3 }))
    #expect(await cross(rig, .milliseconds(29500), thenUntil: { relay.pings == 4 }))
    #expect(!relay.isClosed)
    #expect(await cross(rig, .milliseconds(29500), thenUntil: { relay.isClosed }))
    #expect(relay.pings == 4)
    #expect(rig.connection.status == .connecting)
    #expect(await cross(rig, .milliseconds(2500), thenUntil: { rig.sockets.relays.count == 2 }))
  }

  /// R8: an upgrade that does not open within 15 s is closed and retried.
  @Test func aRelayUpgradeWithoutAnswerIsRetried() async {
    let rig = rig()
    #expect(await cross(rig, .milliseconds(14500), thenUntil: { rig.relay.isClosed }))
    #expect(rig.sockets.relays.count == 1)
    #expect(await cross(rig, .milliseconds(2500), thenUntil: { rig.sockets.relays.count == 2 }))
  }

  // MARK: Rulings after review

  /// КН1: the relay's own `host offline` answer to an attach keeps the terminal; the host's
  /// return re-attaches every open terminal and its stream still delivers.
  @Test func aRelayHostOfflineErrorKeepsTheTerminals() async {
    let rig = rig()
    let relay = await online(rig)
    let logs = ["c1", "c2"].map { RemoteTerminalEventLog(rig.connection.attach(contentID: $0, scrollback: 500)) }
    for content in ["c1", "c2"] {
      let id = Self.lastID(relay, "attach", contentID: content)
      relay.receive(Self.json(["t": "error", "id": id, "message": "host offline"]))
    }
    relay.receive(Self.relayFrame(online: false))
    #expect(await settle { rig.connection.status == .hostOffline })
    relay.receive(Self.relayFrame(online: true))
    #expect(await settle { relay.types.last == "hello" })
    let mark = relay.types.count
    relay.receive(Self.helloFrame())
    #expect(await settle { rig.connection.status == .online(.relay) })
    #expect(Array(relay.types.dropFirst(mark)) == ["list", "watch", "attach", "attach"])
    for (content, log) in zip(["c1", "c2"], logs) {
      #expect(Self.lastText(relay, "attach", contentID: content).contains(#""keep":true"#))
      relay.receive(Self.attached(content, id: Self.lastID(relay, "attach", contentID: content)))
      relay.receive(Self.out(content, "back"))
      #expect(await settle { log.events == [.attached(cols: 120, rows: 40), .out(Array("back".utf8))] })
      #expect(!log.ended)
    }
  }

  /// НТ1: a LAN socket silent for 75 s is closed and the relay takes the traffic back.
  @Test func aSilentLanIsClosedAndTheRelayTakesOver() async {
    let rig = rig()
    let relay = await online(rig)
    let lan = await lanUp(rig, relay: relay)
    #expect(await cross(rig, .milliseconds(29500), thenUntil: { lan.pings == 1 }))
    relay.receive("pong")
    #expect(await cross(rig, .milliseconds(29500), thenUntil: { lan.pings == 2 }))
    relay.receive("pong")
    #expect(!lan.isClosed)
    #expect(await cross(rig, .milliseconds(29500), thenUntil: { lan.isClosed }))
    #expect(lan.pings == 2)
    #expect(await settle { rig.connection.status == .online(.relay) })
    #expect(!relay.isClosed)
  }

  /// НТ2: a LAN path that opens resets the LAN retry delay to 10 s.
  @Test func aLanPathOpeningResetsTheLanBackoff() async {
    let rig = rig()
    let relay = await online(rig, hello: Self.helloFrame(lan: Self.lanAddrs))
    let hellos = { relay.types.count(where: { $0 == "hello" }) }
    rig.lan.drop(reason: "connection failed")
    #expect(await cross(rig, .milliseconds(9500), thenUntil: { hellos() == 2 }))
    let lan = await lanUp(rig, relay: relay)
    lan.drop(reason: "connection lost")
    #expect(await settle { rig.connection.status == .online(.relay) })
    // Without the reset the next ask would come after 20 s.
    #expect(await cross(rig, .milliseconds(9500), thenUntil: { hellos() == 3 }))
  }

  /// НТ3: a request waiting on the LAN ends with `connectionLost` when the LAN socket closes.
  @Test func aLanClosingEndsItsWaits() async {
    let rig = rig()
    let relay = await online(rig)
    let lan = await lanUp(rig, relay: relay)
    let outcome = launch(rig.connection, "worktree.delete")
    #expect(await settle { lan.types.last == "worktree.delete" })
    lan.drop(reason: "connection lost")
    #expect(await settle { outcome.result != nil })
    #expect(outcome.errorKind == .connectionLost)
    #expect(rig.connection.status == .online(.relay))
    #expect(!relay.types.contains("worktree.delete"))
  }

  /// Review F1: the wanted grid waits for the terminal's own `attached`, then goes out once.
  @Test func aWantedGridWaitsForItsOwnAttached() async {
    let rig = rig()
    let relay = await online(rig)
    let log = RemoteTerminalEventLog(rig.connection.attach(contentID: "c1", scrollback: 500))
    rig.connection.setWantedGrid(contentID: "c1", columns: 100, rows: 30)
    #expect(!relay.types.contains("resize"))
    relay.receive(Self.attached("c1", id: Self.lastID(relay, "attach")))
    #expect(await settle { log.events.count == 1 && relay.types.contains("resize") })
    _ = await settle { false }
    #expect(relay.types.count(where: { $0 == "resize" }) == 1)
    #expect(Self.lastText(relay, "resize").contains(#""cols":100"#))
  }

  /// Review F1: after the LAN closed, the grid waits for the relay's re-attach `attached`.
  @Test func aWantedGridAfterTheLanClosedWaitsForTheReattach() async {
    let rig = rig()
    let relay = await online(rig)
    let log = RemoteTerminalEventLog(rig.connection.attach(contentID: "c1", scrollback: 500))
    let lan = await lanUp(rig, relay: relay)
    lan.receive(Self.attached("c1", id: Self.lastID(lan, "attach")))
    #expect(await settle { log.events.count == 1 && relay.types.last == "detach" })
    lan.drop(reason: "connection lost")
    #expect(await settle { rig.connection.status == .online(.relay) && relay.types.last == "attach" })
    rig.connection.setWantedGrid(contentID: "c1", columns: 90, rows: 28)
    #expect(!relay.types.contains("resize"))
    relay.receive(Self.attached("c1", id: Self.lastID(relay, "attach")))
    #expect(await settle { relay.types.contains("resize") })
    _ = await settle { false }
    #expect(relay.types.count(where: { $0 == "resize" }) == 1)
    #expect(Self.lastText(relay, "resize").contains(#""cols":90"#))
  }

  /// Review F2: a `detach` after the host went offline sends nothing on the relay.
  @Test func aDetachAfterTheHostWentOfflineSendsNothing() async {
    let rig = rig()
    let relay = await online(rig)
    let log = RemoteTerminalEventLog(rig.connection.attach(contentID: "c1", scrollback: 500))
    relay.receive(Self.attached("c1", id: Self.lastID(relay, "attach")))
    #expect(await settle { log.events.count == 1 })
    relay.receive(Self.relayFrame(online: false))
    #expect(await settle { rig.connection.status == .hostOffline })
    let sent = relay.sent.count
    rig.connection.detach(contentID: "c1")
    #expect(await settle { log.ended })
    #expect(relay.sent.count == sent)
  }

  // MARK: Lifetime

  @Test func stopClosesBothSocketsAndEndsTheStreams() async {
    let rig = rig()
    let relay = await online(rig)
    let log = RemoteTerminalEventLog(rig.connection.attach(contentID: "c1", scrollback: 500))
    let lan = await lanUp(rig, relay: relay)
    let outcome = launch(rig.connection, "tab.new")
    #expect(await settle { lan.types.last == "tab.new" })
    rig.connection.stop()
    #expect(relay.isClosed)
    #expect(lan.isClosed)
    #expect(rig.connection.status == .idle)
    #expect(await settle { log.ended && outcome.result != nil })
    #expect(outcome.errorKind == .connectionLost)
    await RemoteRouterTestSupport.step(rig.clock, by: .seconds(400), increment: .seconds(5))
    #expect(rig.sockets.relays.count == 1)
    #expect(rig.sockets.lans.count == 1)
    #expect(relay.pings == 0)
  }
}
