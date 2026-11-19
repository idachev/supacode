import ComposableArchitecture
import ConcurrencyExtras
import Foundation
import Sharing
import Testing

@testable import supacode

/// Serialized: the selected Mac is process-wide app storage, so parallel tests would see each other's.
@MainActor
@Suite(.serialized)
struct RemoteClientFeatureTests {
  typealias Event = RemoteClientSessionClient.Event

  /// Stands in for the session: records every call in order and, when `live`, hands out a fresh
  /// event stream per `events()` call (as the session does), which the test feeds.
  final class FakeSession: Sendable {
    let live: Bool
    /// "open <id|nil>" and "close", in call order.
    let log = LockIsolated<[String]>([])
    /// How each stream handed out ended: "finished" or "cancelled".
    let terminations = LockIsolated<[Int: String]>([:])
    private let continuations = LockIsolated<[AsyncStream<Event>.Continuation]>([])

    init(live: Bool = false) {
      self.live = live
    }

    nonisolated deinit {}

    var opens: [String?] {
      log.value.compactMap { entry in
        guard entry.hasPrefix("open ") else { return nil }
        let id = String(entry.dropFirst("open ".count))
        return .some(id == "nil" ? nil : id)
      }
    }

    var closes: Int { log.value.count(where: { $0 == "close" }) }
    var streams: Int { continuations.value.count }

    func events() -> AsyncStream<Event> {
      guard live else { return .finished }
      let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
      let index = continuations.withValue { all in
        all.append(continuation)
        return all.count - 1
      }
      continuation.onTermination = { [terminations] reason in
        let text = if case .cancelled = reason { "cancelled" } else { "finished" }
        terminations.withValue { $0[index] = text }
      }
      return stream
    }

    /// Feeds the newest stream.
    func yield(_ event: Event) {
      continuations.value.last?.yield(event)
    }

    func finishAll() {
      for continuation in continuations.value { continuation.finish() }
    }
  }

  static func host(_ id: String, online: Bool) -> RemoteClientHostInfo { .init(id: id, name: id, online: online) }

  static func list(_ worktrees: [RemoteClientWorktree]) -> RemoteClientList {
    RemoteClientList(repos: [RemoteClientRepository(id: "r", name: "repo", worktrees: worktrees)])
  }

  static func makeStore(
    _ state: RemoteClientFeature.State = RemoteClientFeature.State(),
    hasKeyFile: Bool = true,
    session: FakeSession
  ) -> TestStoreOf<RemoteClientFeature> {
    TestStore(initialState: state) {
      RemoteClientFeature()
    } withDependencies: {
      $0.remoteClientSession = RemoteClientSessionClient(
        hasKeyFile: { hasKeyFile },
        open: { hostID in session.log.withValue { $0.append("open \(hostID ?? "nil")") } },
        close: { session.log.withValue { $0.append("close") } },
        events: { session.events() },
        ownHostID: { "me" }
      )
    }
  }

  /// The effect subscribes and opens off the test's own task: wait for it.
  private func settle(_ condition: () -> Bool) async -> Bool {
    await RemoteRouterTestSupport.settle(condition)
  }

  @Test func withoutAKeyFileTheWindowExplainsAndDoesNotConnect() async {
    let session = FakeSession()
    let store = Self.makeStore(hasKeyFile: false, session: session)
    await store.send(.windowAppeared) {
      $0.hasKeyFile = false
      $0.ownHostID = "me"
    }
    await store.finish()
    #expect(session.opens.isEmpty)
    // A connection left from an earlier opening (the key was removed since) is closed.
    #expect(session.closes == 1)
  }

  @Test func theSavedHostIsOpenedOnAppear() async {
    @Shared(.appStorage(RemoteClientFeature.selectedHostKey)) var saved: String?
    $saved.withLock { $0 = "a" }
    defer { $saved.withLock { $0 = nil } }
    let session = FakeSession()
    let store = Self.makeStore(session: session)
    await store.send(.windowAppeared) {
      $0.ownHostID = "me"
    }
    await store.finish()
    #expect(session.opens == ["a"])
  }

  @Test func nothingSavedAndOneOtherMacOnlineSelectsIt() async {
    @Shared(.appStorage(RemoteClientFeature.selectedHostKey)) var saved: String?
    $saved.withLock { $0 = nil }
    defer { $saved.withLock { $0 = nil } }
    let session = FakeSession(live: true)
    let store = Self.makeStore(session: session)
    await store.send(.windowAppeared) {
      $0.ownHostID = "me"
    }
    #expect(await settle { session.opens.count == 1 })
    let hosts = [Self.host("me", online: true), Self.host("a", online: true)]
    session.yield(.hostsChanged(hosts))
    await store.receive(\.hostsChanged) {
      $0.hosts = hosts
      $0.$selectedHostID.withLock { $0 = "a" }
    }
    #expect(await settle { session.opens.count == 2 })
    session.finishAll()
    await store.finish()
    #expect(session.opens == [nil, "a"])
    // The reopen replaced the unbound subscription.
    #expect(session.terminations.value[0] == "cancelled")
  }

  @Test func nothingSavedAndTwoOnlineAsks() async {
    @Shared(.appStorage(RemoteClientFeature.selectedHostKey)) var saved: String?
    $saved.withLock { $0 = nil }
    defer { $saved.withLock { $0 = nil } }
    let session = FakeSession()
    let store = Self.makeStore(session: session)
    await store.send(.windowAppeared) {
      $0.ownHostID = "me"
    }
    let hosts = [Self.host("me", online: true), Self.host("a", online: true), Self.host("b", online: true)]
    await store.send(.hostsChanged(hosts)) {
      $0.hosts = hosts
      $0.isHostPickerPresented = true
    }
    await store.finish()
    #expect(session.opens == [nil])
    #expect(store.state.pickableHosts.map(\.id) == ["a", "b"])
  }

  @Test func aSavedHostMissingFromTheListAsksAndKeepsTheSelection() async {
    @Shared(.appStorage(RemoteClientFeature.selectedHostKey)) var saved: String?
    $saved.withLock { $0 = "gone" }
    defer { $saved.withLock { $0 = nil } }
    let session = FakeSession()
    let store = Self.makeStore(session: session)
    await store.send(.windowAppeared) {
      $0.ownHostID = "me"
    }
    let hosts = [Self.host("a", online: true)]
    await store.send(.hostsChanged(hosts)) {
      $0.hosts = hosts
      $0.isHostPickerPresented = true
    }
    await store.finish()
    #expect(store.state.selectedHostID == "gone")
    #expect(session.opens == ["gone"])
  }

  @Test func aSavedHostThatIsThisMacAsks() async {
    @Shared(.appStorage(RemoteClientFeature.selectedHostKey)) var saved: String?
    $saved.withLock { $0 = "me" }
    defer { $saved.withLock { $0 = nil } }
    let session = FakeSession()
    let store = Self.makeStore(session: session)
    await store.send(.windowAppeared) {
      $0.ownHostID = "me"
    }
    let hosts = [Self.host("me", online: true), Self.host("a", online: true)]
    await store.send(.hostsChanged(hosts)) {
      $0.hosts = hosts
      $0.isHostPickerPresented = true
    }
    await store.finish()
    #expect(store.state.selectedHostID == "me")
    #expect(session.opens == ["me"])
  }

  @Test func selectingAloneClosesAPickerAlreadyOpen() async {
    @Shared(.appStorage(RemoteClientFeature.selectedHostKey)) var saved: String?
    $saved.withLock { $0 = nil }
    defer { $saved.withLock { $0 = nil } }
    let session = FakeSession()
    var state = RemoteClientFeature.State()
    state.ownHostID = "me"
    state.isHostPickerPresented = true
    let store = Self.makeStore(state, session: session)
    let hosts = [Self.host("me", online: true), Self.host("a", online: true)]
    await store.send(.hostsChanged(hosts)) {
      $0.hosts = hosts
      $0.$selectedHostID.withLock { $0 = "a" }
      $0.isHostPickerPresented = false
    }
    await store.finish()
    #expect(session.opens == ["a"])
  }

  @Test func pickingAHostClearsTheOldMacsState() async {
    @Shared(.appStorage(RemoteClientFeature.selectedHostKey)) var saved: String?
    $saved.withLock { $0 = "a" }
    defer { $saved.withLock { $0 = nil } }
    let session = FakeSession()
    var state = RemoteClientFeature.State()
    state.list = Self.list([RemoteClientWorktree(id: "w1", name: "one")])
    state.selectedWorktreeID = "w1"
    state.isHostPickerPresented = true
    let store = Self.makeStore(state, session: session)
    await store.send(.hostPicked("b")) {
      $0.$selectedHostID.withLock { $0 = "b" }
      $0.list = nil
      $0.selectedWorktreeID = nil
      $0.isHostPickerPresented = false
    }
    await store.finish()
    #expect(session.opens == ["b"])
  }

  @Test func anOldRelayNeverShowsThePicker() async {
    @Shared(.appStorage(RemoteClientFeature.selectedHostKey)) var saved: String?
    $saved.withLock { $0 = nil }
    defer { $saved.withLock { $0 = nil } }
    let session = FakeSession()
    let store = Self.makeStore(session: session)
    await store.send(.windowAppeared) {
      $0.ownHostID = "me"
    }
    await store.send(.hostsChanged(nil))
    await store.finish()
    #expect(session.opens == [nil])
  }

  @Test func theFirstListSelectsTheWorktreeTheMacShows() async {
    let session = FakeSession(live: true)
    let store = Self.makeStore(session: session)
    await store.send(.windowAppeared) {
      $0.ownHostID = "me"
    }
    #expect(await settle { session.opens.count == 1 })
    let shown = Self.list([
      RemoteClientWorktree(id: "w1", name: "one"), RemoteClientWorktree(id: "w2", name: "two", focused: true),
    ])
    session.yield(.listChanged(shown))
    await store.receive(\.listChanged) {
      $0.list = shown
      $0.selectedWorktreeID = "w2"
    }
    // The laptop's own choice stays while that worktree exists (СЛ4).
    await store.send(.worktreeSelected("w1")) {
      $0.selectedWorktreeID = "w1"
    }
    session.yield(.listChanged(shown))
    await store.receive(\.listChanged)
    // Gone from the Mac: the rule picks again, the first one without a focused worktree.
    let without = Self.list([
      RemoteClientWorktree(id: "w3", name: "three"), RemoteClientWorktree(id: "w4", name: "four"),
    ])
    session.yield(.listChanged(without))
    await store.receive(\.listChanged) {
      $0.list = without
      $0.selectedWorktreeID = "w3"
    }
    session.finishAll()
    await store.finish()
  }

  @Test func statusAndNameEventsReachTheState() async {
    let session = FakeSession(live: true)
    let store = Self.makeStore(session: session)
    await store.send(.windowAppeared) {
      $0.ownHostID = "me"
    }
    #expect(await settle { session.opens.count == 1 })
    session.yield(.statusChanged(.online(.lan)))
    await store.receive(\.statusChanged) {
      $0.status = .online(.lan)
    }
    session.yield(.hostNameChanged("Office Mac"))
    await store.receive(\.hostNameChanged) {
      $0.hostName = "Office Mac"
    }
    session.finishAll()
    await store.finish()
  }

  @Test func appearingAgainCancelsThePreviousEvents() async {
    let session = FakeSession(live: true)
    let store = Self.makeStore(session: session)
    await store.send(.windowAppeared) {
      $0.ownHostID = "me"
    }
    #expect(await settle { session.opens.count == 1 })
    // "Try Again": a second appearance replaces the first subscription and opens again.
    await store.send(.windowAppeared)
    #expect(await settle { session.opens.count == 2 && session.terminations.value[0] != nil })
    #expect(session.terminations.value[0] == "cancelled")
    #expect(session.streams == 2)
    // Only the newest subscription reaches the store.
    session.yield(.statusChanged(.connecting))
    await store.receive(\.statusChanged) {
      $0.status = .connecting
    }
    session.finishAll()
    await store.finish()
    #expect(session.opens == [nil, nil])
  }

  @Test func theTitleOpensThePickerAndDismissingClosesIt() async {
    let session = FakeSession()
    let store = Self.makeStore(session: session)
    await store.send(.titleTapped) {
      $0.isHostPickerPresented = true
    }
    await store.send(.hostPickerDismissed) {
      $0.isHostPickerPresented = false
    }
    #expect(session.opens.isEmpty)
  }

  @Test func closingTheWindowClosesTheSession() async {
    let session = FakeSession(live: true)
    var state = RemoteClientFeature.State()
    state.list = Self.list([RemoteClientWorktree(id: "w1", name: "one")])
    state.selectedWorktreeID = "w1"
    state.hostName = "Office Mac"
    state.status = .online(.relay)
    state.hosts = [Self.host("a", online: true)]
    let store = Self.makeStore(state, session: session)
    await store.send(.windowAppeared) {
      $0.ownHostID = "me"
    }
    #expect(await settle { session.opens.count == 1 })
    // The events effect is still running; closing the window must end it.
    await store.send(.windowClosed) {
      $0.status = .idle
      $0.hostName = nil
      $0.hosts = []
      $0.list = nil
      $0.selectedWorktreeID = nil
    }
    await store.finish()
    #expect(session.closes == 1)
    #expect(session.terminations.value[0] == "cancelled")
  }

  /// A Mac chosen alone right before the window closes must not connect after the close (КЛ6).
  @Test func aSelectionRightBeforeClosingNeverOpensAfterTheClose() async {
    @Shared(.appStorage(RemoteClientFeature.selectedHostKey)) var saved: String?
    $saved.withLock { $0 = nil }
    defer { $saved.withLock { $0 = nil } }
    let session = FakeSession(live: true)
    let store = Self.makeStore(session: session)
    await store.send(.windowAppeared) {
      $0.ownHostID = "me"
    }
    #expect(await settle { session.opens.count == 1 })
    let hosts = [Self.host("me", online: true), Self.host("a", online: true)]
    await store.send(.hostsChanged(hosts)) {
      $0.hosts = hosts
      $0.$selectedHostID.withLock { $0 = "a" }
    }
    await store.send(.windowClosed) {
      $0.hosts = []
    }
    await store.finish()
    session.finishAll()
    let log = session.log.value
    let closeIndex = log.lastIndex(of: "close")
    #expect(closeIndex != nil)
    if let closeIndex {
      #expect(!log[(closeIndex + 1)...].contains { $0.hasPrefix("open") })
    }
  }
}
