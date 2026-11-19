import Clocks
import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

/// The session's report bridge, driven through a real `RemoteClientConnection` on fake sockets.
/// Remote contents (they need live Ghostty surfaces) are left out.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RemoteClientSessionTests {
  typealias Event = RemoteClientSessionClient.Event

  /// Collects one subscription's reports.
  @MainActor
  final class EventLog {
    private(set) var events: [Event] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<Event>) {
      task = Task { [weak self] in
        for await event in stream { self?.events.append(event) }
      }
    }

    nonisolated deinit {}
  }

  struct Rig {
    let session: RemoteClientSession
    let sockets: FakeClientSockets
    let directory: URL
    let clock: TestClock<Duration>

    func cleanUp() {
      session.close()
      try? FileManager.default.removeItem(at: directory)
    }
  }

  /// A session on fake sockets with its pipe socket in a fresh short directory (`sun_path`).
  private func rig(pipeDirectory: URL? = nil) -> Rig {
    let sockets = FakeClientSockets()
    let directory = pipeDirectory ?? URL(filePath: "/tmp/sc-test-\(UUID().uuidString.prefix(8))")
    let clock = TestClock<Duration>()
    let session = RemoteClientSession(
      ghostty: GhosttyRuntime(),
      sockets: sockets.factory,
      clock: clock,
      pipeDirectory: directory,
      ownHostID: "me",
      loadKey: { RemoteClientConnectionTests.key }
    )
    return Rig(session: session, sockets: sockets, directory: directory, clock: clock)
  }

  private func settle(_ condition: () -> Bool) async -> Bool {
    await RemoteRouterTestSupport.settle(condition)
  }

  static let listText = #"{"t":"list","repos":[{"id":"r1","name":"supacode"}]}"#

  /// Opens the newest relay, brings the host online and answers `hello`.
  private func online(_ rig: Rig) async {
    let relay = rig.sockets.relays[rig.sockets.relays.count - 1]
    relay.open()
    relay.receive(RemoteClientConnectionTests.relayFrame(online: true))
    #expect(await settle { relay.types.last == "hello" })
    relay.receive(RemoteClientConnectionTests.helloFrame())
    #expect(await settle { rig.session.connection?.status == .online(.relay) })
  }

  private static func isList(_ event: Event) -> Bool {
    if case .listChanged = event { true } else { false }
  }

  @Test func theBridgeReportsOnlyRealChanges() async throws {
    let rig = rig()
    defer { rig.cleanUp() }
    let log = EventLog(rig.session.events())
    rig.session.open(hostID: "h1")
    #expect(await settle { log.events == [.statusChanged(.connecting)] })

    await online(rig)
    let relay = rig.sockets.relays[0]
    // The same relay frame again, and a ping answer, change nothing.
    relay.receive(RemoteClientConnectionTests.relayFrame(online: true))
    relay.receive(RemoteClientConnection.pongText)
    relay.receive(Self.listText)
    #expect(await settle { log.events.contains(where: Self.isList) })
    let list = try #require(rig.session.connection?.list)
    let hosts = [RemoteClientHostInfo(id: "h1", name: "Office Mac", online: true)]
    #expect(
      log.events == [
        .statusChanged(.connecting),
        .hostsChanged(hosts),
        .statusChanged(.online(.relay)),
        .hostNameChanged("Office Mac"),
        .listChanged(list),
      ])
  }

  @Test func aReplacedConnectionReportsNothingAndTheNextListStillArrives() async {
    let rig = rig()
    defer { rig.cleanUp() }
    let log = EventLog(rig.session.events())
    rig.session.open(hostID: "h1")
    await online(rig)
    rig.sockets.relays[0].receive(Self.listText)
    #expect(await settle { log.events.contains(where: Self.isList) })
    let mark = log.events.count
    // Held, so the old connection outlives its replacement: only the session's guard keeps its
    // late changes out (without the hold, the weak capture alone would).
    let old = rig.session.connection
    defer { withExtendedLifetime(old) {} }

    rig.session.open(hostID: "h2")
    #expect(rig.sockets.relays.count == 2)
    #expect(rig.sockets.relays[0].isClosed)
    // The old connection stopping (status `.idle`) is not reported: it is no longer the session's.
    #expect(await settle { log.events.count == mark + 3 })
    #expect(
      Array(log.events[mark...]) == [.statusChanged(.connecting), .hostNameChanged(nil), .hostsChanged(nil)])

    // The new connection's first list is reported, though it counts lists from zero again.
    await online(rig)
    rig.sockets.relays[1].receive(Self.listText)
    #expect(await settle { log.events[mark...].contains(where: Self.isList) })
    #expect(!log.events.contains(.statusChanged(.idle)))
  }

  @Test func closingStopsEverythingAndTheNextOpeningReportsAfresh() async {
    let rig = rig()
    defer { rig.cleanUp() }
    let first = EventLog(rig.session.events())
    rig.session.open(hostID: "h1")
    #expect(await settle { first.events == [.statusChanged(.connecting)] })
    #expect(FileManager.default.fileExists(atPath: rig.session.pipes.socketPath))

    rig.session.close()
    #expect(rig.session.connection == nil)
    #expect(rig.sockets.relays[0].isClosed)
    #expect(!FileManager.default.fileExists(atPath: rig.session.pipes.socketPath))

    // The window reset its copy on close: the same status is reported again to the next window.
    let second = EventLog(rig.session.events())
    rig.session.open(hostID: "h1")
    #expect(await settle { second.events == [.statusChanged(.connecting)] })
    #expect(FileManager.default.fileExists(atPath: rig.session.pipes.socketPath))
  }

  @Test func aPipeServerThatCannotListenFailsTheWindowWithoutConnecting() async throws {
    // A regular file where the pipe directory should be: the directory cannot be made.
    let blocker = URL(filePath: "/tmp/sc-test-\(UUID().uuidString.prefix(8))")
    try Data().write(to: blocker)
    let rig = rig(pipeDirectory: blocker)
    defer { rig.cleanUp() }
    let log = EventLog(rig.session.events())
    rig.session.open(hostID: "h1")
    #expect(await settle { !log.events.isEmpty })
    #expect(log.events == [.statusChanged(.failed(RemoteClientSession.pipeServerFailure))])
    #expect(rig.session.connection == nil)
    #expect(rig.sockets.relays.isEmpty)
  }

  @Test func theKeyFileIsReadThroughTheInjectedLoader() {
    let with = rig()
    defer { with.cleanUp() }
    #expect(with.session.hasKeyFile)
    let without = RemoteClientSession(
      ghostty: GhosttyRuntime(), sockets: FakeClientSockets().factory, clock: TestClock<Duration>(),
      pipeDirectory: with.directory, ownHostID: "me", loadKey: { nil })
    #expect(!without.hasKeyFile)
    without.open(hostID: nil)
    #expect(without.connection == nil)
  }
  // MARK: - Attached set on the clock (РЗ5)

  /// What the driver asked for, in order: "+id" attach, "-id" detach.
  @MainActor
  final class AttachLog {
    private(set) var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
    nonisolated deinit {}
  }

  private func driver(_ clock: TestClock<Duration>) -> (RemoteAttachedSetDriver, AttachLog) {
    let driver = RemoteAttachedSetDriver(clock: clock)
    let log = AttachLog()
    driver.onAttach = { log.append("+\($0)") }
    driver.onDetach = { log.append("-\($0)") }
    return (driver, log)
  }

  @Test func theAttachedSetDetachesBeforeItAttaches() {
    let (driver, log) = driver(TestClock<Duration>())
    let first = (0..<16).map { "a\($0)" }
    let second = (0..<16).map { "b\($0)" }
    driver.setVisible(first)
    #expect(log.entries == first.map { "+\($0)" })
    // Sixteen new ones push the sixteen hidden ones out; they leave the wire first.
    driver.setVisible(second)
    let step = Array(log.entries.dropFirst(16))
    #expect(step == first.sorted().map { "-\($0)" } + second.map { "+\($0)" })
  }

  @Test func aHiddenContentIsDetachedThirtySecondsLaterOnTheClock() async {
    let clock = TestClock<Duration>()
    let (driver, log) = driver(clock)
    driver.setVisible(["x"])
    driver.setVisible([])
    await RemoteRouterTestSupport.step(clock, by: .seconds(29))
    #expect(log.entries == ["+x"])
    #expect(await RemoteRouterTestSupport.step(clock, until: { log.entries == ["+x", "-x"] }, within: .seconds(2)))
    withExtendedLifetime(driver) {}
  }

  @Test func aQuickSwitchBackKeepsItAttachedAndNothingRunsAfterReset() async {
    let clock = TestClock<Duration>()
    let (driver, log) = driver(clock)
    driver.setVisible(["x"])
    driver.setVisible(["y"])
    await RemoteRouterTestSupport.step(clock, by: .seconds(20))
    // Shown again within 30 s: no re-attach, and its expiry is called off.
    driver.setVisible(["x"])
    await RemoteRouterTestSupport.step(clock, by: .seconds(40))
    #expect(log.entries == ["+x", "+y", "-y"])
    driver.setVisible([])
    await RemoteRouterTestSupport.step(clock, by: .seconds(10))
    // The connection went: the driver forgets everything and its timer never fires.
    driver.reset()
    await RemoteRouterTestSupport.step(clock, by: .seconds(40))
    #expect(log.entries == ["+x", "+y", "-y"])
    // After the reset a visible content is new again.
    driver.setVisible(["x"])
    #expect(log.entries == ["+x", "+y", "-y", "+x"])
    withExtendedLifetime(driver) {}
  }

  @Test func setVisibleWithoutAConnectionDoesNothing() {
    let rig = rig()
    defer { rig.cleanUp() }
    rig.session.setVisible(["c1"])
    #expect(rig.session.attachedContent("c1") == nil)
    #expect(rig.session.fittingGrid("P1") == nil)
  }
  /// The session's own wiring of the attached set: a content is made once, torn down when its
  /// linger ends, and forgotten by a new `open` and by `close`. A content whose surface does not start
  /// in the test host is kept too, so these hold either way.
  @Test func visibleContentsAreMadeOnceAndGoWithTheirLingerOrTheConnection() async throws {
    let rig = rig()
    defer { rig.cleanUp() }
    rig.session.open(hostID: "h1")
    rig.session.setVisible(["c1"])
    let first = try #require(rig.session.attachedContent("c1"))
    rig.session.setVisible(["c1"])
    #expect(rig.session.attachedContent("c1") === first)

    rig.session.setVisible([])
    #expect(rig.session.attachedContent("c1") === first)
    #expect(
      await RemoteRouterTestSupport.step(
        rig.clock, until: { rig.session.attachedContent("c1") == nil }, within: .seconds(32)))

    rig.session.setVisible(["c1"])
    let second = try #require(rig.session.attachedContent("c1"))
    #expect(second !== first)
    // A new connection tears every content down; the set made afresh.
    rig.session.open(hostID: "h1")
    #expect(rig.session.attachedContent("c1") == nil)
    rig.session.setVisible(["c1"])
    let third = try #require(rig.session.attachedContent("c1"))
    #expect(third !== second)

    rig.session.close()
    #expect(rig.session.attachedContent("c1") == nil)
    rig.session.setVisible(["c1"])
    #expect(rig.session.attachedContent("c1") == nil)
  }

  /// БН1: every content learns the link's status and the Mac's name when the session does.
  @Test func contentsFollowTheConnectionsStatusAndName() async throws {
    let rig = rig()
    defer { rig.cleanUp() }
    rig.session.open(hostID: "h1")
    await online(rig)
    #expect(await settle { rig.session.connection?.hostName == "Office Mac" })
    rig.session.setVisible(["c1"])
    let content = try #require(rig.session.attachedContent("c1"))
    // A content made while online starts from the live status, not from a default.
    #expect(content.status == .online(.relay))
    #expect(content.hostName == "Office Mac")
    #expect(content.bannerText == "Connecting to Office Mac…")

    rig.sockets.relays[rig.sockets.relays.count - 1].drop(reason: "connection lost")
    #expect(await settle { content.status == .connecting })
    // Never attached on this connection: connecting, not a lost link.
    #expect(content.bannerText == "Connecting to Office Mac…")
  }

  /// Two worktrees hold a pane with this id: the one whose tab is shown answers, not the first one.
  @Test func theFittingGridSkipsAWorktreeWhosePaneIsNotShown() async throws {
    let rig = rig()
    defer { rig.cleanUp() }
    rig.session.open(hostID: "h1")
    await online(rig)
    func worktree(_ id: String, tab: String) -> String {
      """
      {"id":"\(id)","tabs":[{"id":"\(tab)","contentId":"c-\(tab)","title":"zsh"}],\
      "layout":{"mode":"tabsPerSplit","activeGroupId":"main","groups":[],\
      "panes":[{"id":"P1","tabIds":["\(tab)"],"selectedTabId":"\(tab)"}]}}
      """
    }
    rig.sockets.relays[0].receive(
      #"{"t":"list","repos":[{"id":"r","name":"r","worktrees":["#
        + worktree("w1", tab: "t1") + "," + worktree("w2", tab: "t2") + "]}]}")
    #expect(await settle { rig.session.connection?.list?.repos.first?.worktrees.count == 2 })
    rig.session.setVisible(["c-t2"])
    let content = try #require(rig.session.attachedContent("c-t2"))
    content.paneMeasured(RemoteAutoResize.Grid(columns: 100, rows: 30))
    #expect(rig.session.fittingGrid("P1") == RemoteAutoResize.Grid(columns: 100, rows: 30))
  }
}
