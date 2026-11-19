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
  /// What the reducer asked of the session.
  final class Calls: Sendable {
    let opens = LockIsolated<[String?]>([])
    let closes = LockIsolated(0)

    nonisolated deinit {}
  }

  static func host(_ id: String, online: Bool) -> RemoteClientHostInfo { .init(id: id, name: id, online: online) }

  static func list(_ worktrees: [RemoteClientWorktree]) -> RemoteClientList {
    RemoteClientList(repos: [RemoteClientRepository(id: "r", name: "repo", worktrees: worktrees)])
  }

  /// A store whose session records calls and whose event stream the test drives.
  static func makeStore(
    _ state: RemoteClientFeature.State = RemoteClientFeature.State(),
    hasKeyFile: Bool = true,
    calls: Calls,
    events: AsyncStream<RemoteClientSessionClient.Event> = .finished
  ) -> TestStoreOf<RemoteClientFeature> {
    TestStore(initialState: state) {
      RemoteClientFeature()
    } withDependencies: {
      $0.remoteClientSession = RemoteClientSessionClient(
        hasKeyFile: { hasKeyFile },
        open: { hostID in calls.opens.withValue { $0.append(hostID) } },
        close: { calls.closes.withValue { $0 += 1 } },
        events: { events },
        ownHostID: { "me" }
      )
    }
  }

  @Test func withoutAKeyFileTheWindowExplainsAndDoesNotConnect() async {
    let calls = Calls()
    let store = Self.makeStore(hasKeyFile: false, calls: calls)
    await store.send(.windowAppeared) {
      $0.hasKeyFile = false
      $0.ownHostID = "me"
    }
    await store.finish()
    #expect(calls.opens.value.isEmpty)
    // A connection left from an earlier opening (the key was removed since) is closed.
    #expect(calls.closes.value == 1)
  }

  @Test func theSavedHostIsOpenedOnAppear() async {
    @Shared(.appStorage(RemoteClientFeature.selectedHostKey)) var saved: String?
    $saved.withLock { $0 = "a" }
    defer { $saved.withLock { $0 = nil } }
    let calls = Calls()
    let store = Self.makeStore(calls: calls)
    await store.send(.windowAppeared) {
      $0.ownHostID = "me"
    }
    await store.finish()
    #expect(calls.opens.value == ["a"])
  }

  @Test func nothingSavedAndOneOtherMacOnlineSelectsIt() async {
    @Shared(.appStorage(RemoteClientFeature.selectedHostKey)) var saved: String?
    $saved.withLock { $0 = nil }
    defer { $saved.withLock { $0 = nil } }
    let calls = Calls()
    let (events, continuation) = AsyncStream.makeStream(of: RemoteClientSessionClient.Event.self)
    let store = Self.makeStore(calls: calls, events: events)
    await store.send(.windowAppeared) {
      $0.ownHostID = "me"
    }
    let hosts = [Self.host("me", online: true), Self.host("a", online: true)]
    continuation.yield(.hostsChanged(hosts))
    await store.receive(\.hostsChanged) {
      $0.hosts = hosts
      $0.$selectedHostID.withLock { $0 = "a" }
    }
    continuation.finish()
    await store.finish()
    #expect(calls.opens.value == [nil, "a"])
  }

  @Test func nothingSavedAndTwoOnlineAsks() async {
    @Shared(.appStorage(RemoteClientFeature.selectedHostKey)) var saved: String?
    $saved.withLock { $0 = nil }
    defer { $saved.withLock { $0 = nil } }
    let calls = Calls()
    let store = Self.makeStore(calls: calls)
    await store.send(.windowAppeared) {
      $0.ownHostID = "me"
    }
    let hosts = [Self.host("me", online: true), Self.host("a", online: true), Self.host("b", online: true)]
    await store.send(.hostsChanged(hosts)) {
      $0.hosts = hosts
      $0.isHostPickerPresented = true
    }
    await store.finish()
    #expect(calls.opens.value == [nil])
    #expect(store.state.pickableHosts.map(\.id) == ["a", "b"])
  }

  @Test func aSavedHostMissingFromTheListAsksAndKeepsTheSelection() async {
    @Shared(.appStorage(RemoteClientFeature.selectedHostKey)) var saved: String?
    $saved.withLock { $0 = "gone" }
    defer { $saved.withLock { $0 = nil } }
    let calls = Calls()
    let store = Self.makeStore(calls: calls)
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
    #expect(calls.opens.value == ["gone"])
  }

  @Test func aSavedHostThatIsThisMacAsks() async {
    @Shared(.appStorage(RemoteClientFeature.selectedHostKey)) var saved: String?
    $saved.withLock { $0 = "me" }
    defer { $saved.withLock { $0 = nil } }
    let calls = Calls()
    let store = Self.makeStore(calls: calls)
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
    #expect(calls.opens.value == ["me"])
  }

  @Test func pickingAHostClearsTheOldMacsState() async {
    @Shared(.appStorage(RemoteClientFeature.selectedHostKey)) var saved: String?
    $saved.withLock { $0 = "a" }
    defer { $saved.withLock { $0 = nil } }
    let calls = Calls()
    var state = RemoteClientFeature.State()
    state.list = Self.list([RemoteClientWorktree(id: "w1", name: "one")])
    state.selectedWorktreeID = "w1"
    state.isHostPickerPresented = true
    let store = Self.makeStore(state, calls: calls)
    await store.send(.hostPicked("b")) {
      $0.$selectedHostID.withLock { $0 = "b" }
      $0.list = nil
      $0.selectedWorktreeID = nil
      $0.isHostPickerPresented = false
    }
    await store.finish()
    #expect(calls.opens.value == ["b"])
  }

  @Test func anOldRelayNeverShowsThePicker() async {
    @Shared(.appStorage(RemoteClientFeature.selectedHostKey)) var saved: String?
    $saved.withLock { $0 = nil }
    defer { $saved.withLock { $0 = nil } }
    let calls = Calls()
    let store = Self.makeStore(calls: calls)
    await store.send(.windowAppeared) {
      $0.ownHostID = "me"
    }
    await store.send(.hostsChanged(nil))
    await store.finish()
    #expect(calls.opens.value == [nil])
  }

  @Test func theFirstListSelectsTheWorktreeTheMacShows() async {
    let calls = Calls()
    let (events, continuation) = AsyncStream.makeStream(of: RemoteClientSessionClient.Event.self)
    let store = Self.makeStore(calls: calls, events: events)
    await store.send(.windowAppeared) {
      $0.ownHostID = "me"
    }
    let shown = Self.list([
      RemoteClientWorktree(id: "w1", name: "one"), RemoteClientWorktree(id: "w2", name: "two", focused: true),
    ])
    continuation.yield(.listChanged(shown))
    await store.receive(\.listChanged) {
      $0.list = shown
      $0.selectedWorktreeID = "w2"
    }
    // The laptop's own choice stays while that worktree exists (СЛ4).
    await store.send(.worktreeSelected("w1")) {
      $0.selectedWorktreeID = "w1"
    }
    continuation.yield(.listChanged(shown))
    await store.receive(\.listChanged)
    // Gone from the Mac: the rule picks again, the first one without a focused worktree.
    let without = Self.list([
      RemoteClientWorktree(id: "w3", name: "three"), RemoteClientWorktree(id: "w4", name: "four"),
    ])
    continuation.yield(.listChanged(without))
    await store.receive(\.listChanged) {
      $0.list = without
      $0.selectedWorktreeID = "w3"
    }
    continuation.finish()
    await store.finish()
  }

  @Test func statusAndNameEventsReachTheState() async {
    let calls = Calls()
    let (events, continuation) = AsyncStream.makeStream(of: RemoteClientSessionClient.Event.self)
    let store = Self.makeStore(calls: calls, events: events)
    await store.send(.windowAppeared) {
      $0.ownHostID = "me"
    }
    continuation.yield(.statusChanged(.online(.lan)))
    await store.receive(\.statusChanged) {
      $0.status = .online(.lan)
    }
    continuation.yield(.hostNameChanged("Office Mac"))
    await store.receive(\.hostNameChanged) {
      $0.hostName = "Office Mac"
    }
    continuation.finish()
    await store.finish()
  }

  @Test func theTitleOpensThePickerAndDismissingClosesIt() async {
    let calls = Calls()
    let store = Self.makeStore(calls: calls)
    await store.send(.titleTapped) {
      $0.isHostPickerPresented = true
    }
    await store.send(.hostPickerDismissed) {
      $0.isHostPickerPresented = false
    }
    #expect(calls.opens.value.isEmpty)
  }

  @Test func closingTheWindowClosesTheSession() async {
    let calls = Calls()
    let (events, continuation) = AsyncStream.makeStream(of: RemoteClientSessionClient.Event.self)
    defer { continuation.finish() }
    var state = RemoteClientFeature.State()
    state.list = Self.list([RemoteClientWorktree(id: "w1", name: "one")])
    state.selectedWorktreeID = "w1"
    state.hostName = "Office Mac"
    state.status = .online(.relay)
    state.hosts = [Self.host("a", online: true)]
    let store = Self.makeStore(state, calls: calls, events: events)
    await store.send(.windowAppeared) {
      $0.ownHostID = "me"
    }
    // The events effect is still running; closing the window must end it.
    await store.send(.windowClosed) {
      $0.status = .idle
      $0.hostName = nil
      $0.hosts = []
      $0.list = nil
      $0.selectedWorktreeID = nil
    }
    await store.finish()
    #expect(calls.closes.value == 1)
  }
}
