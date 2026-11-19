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

    func cleanUp() {
      session.close()
      try? FileManager.default.removeItem(at: directory)
    }
  }

  /// A session on fake sockets with its pipe socket in a fresh short directory (`sun_path`).
  private func rig(pipeDirectory: URL? = nil) -> Rig {
    let sockets = FakeClientSockets()
    let directory = pipeDirectory ?? URL(filePath: "/tmp/sc-test-\(UUID().uuidString.prefix(8))")
    let session = RemoteClientSession(
      ghostty: GhosttyRuntime(),
      sockets: sockets.factory,
      clock: TestClock<Duration>(),
      pipeDirectory: directory,
      ownHostID: "me",
      loadKey: { RemoteClientConnectionTests.key }
    )
    return Rig(session: session, sockets: sockets, directory: directory)
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
}
