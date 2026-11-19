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
  /// One `request` call.
  struct Sent: Equatable, Sendable {
    let type: String
    let fields: [String: String]
    let ints: [String: Int]
    let timeout: Duration
  }

  final class FakeSession: Sendable {
    typealias Reply = @Sendable (Sent) async throws -> [String: String]

    let live: Bool
    /// "open <id|nil>" and "close", in call order.
    let log = LockIsolated<[String]>([])
    /// Every `request`, in call order.
    let sent = LockIsolated<[Sent]>([])
    /// Every `setVisible`, in call order.
    let visible = LockIsolated<[[String]]>([])
    /// `fittingGrid` by pane id.
    let grids = LockIsolated<[String: RemoteAutoResize.Grid]>([:])
    /// How `request` answers; by default an empty reply at once.
    let reply = LockIsolated<Reply>({ _ in [:] })
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
    RemoteClientList(
      repos: [RemoteClientRepository(id: "r", name: "repo", canCreateWorktree: true, worktrees: worktrees)],
      canRefreshWorktrees: true)
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
        ownHostID: { "me" },
        request: { type, fields, ints, timeout in
          let sent = Sent(type: type, fields: fields, ints: ints, timeout: timeout)
          session.sent.withValue { $0.append(sent) }
          return try await session.reply.value(sent)
        },
        setVisible: { ids in session.visible.withValue { $0.append(ids) } },
        fittingGrid: { session.grids.value[$0] }
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
    // Worktrees without tabs: an empty projection, nothing visible.
    let empty = RemoteLayoutProjection(mode: "tabsPerSplit", groups: [], activeGroupID: nil, panes: [:])
    await store.receive(\.listChanged) {
      $0.list = shown
      $0.sidebarSections = RemoteSidebarModel.sections(shown, filter: "")
      $0.selectedWorktreeID = "w2"
      $0.selections = ["w2": RemoteLocalSelection()]
      $0.projection = empty
    }
    // The laptop's own choice stays while that worktree exists (СЛ4).
    await store.send(.worktreeSelected("w1")) {
      $0.selectedWorktreeID = "w1"
      $0.selections["w1"] = RemoteLocalSelection()
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
      $0.sidebarSections = RemoteSidebarModel.sections(without, filter: "")
      $0.selectedWorktreeID = "w3"
      $0.selections = ["w3": RemoteLocalSelection()]
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
  // MARK: - Sidebar, selection and remote actions

  static func tab(_ id: String, working: Bool = false) -> RemoteClientTab {
    RemoteClientTab(id: id, contentId: "c-\(id)", title: "title-\(id)", working: working)
  }

  /// Panes P1 [t1, t2 selected t2] and P2 [t3] side by side in the group `main`, focused P2.
  static func twoPane(
    _ id: String = "w1", tabs: [RemoteClientTab]? = nil, extraPanes: [RemoteClientLayoutPane] = [],
    tree: RemoteClientLayoutNode? = nil
  ) -> RemoteClientWorktree {
    RemoteClientWorktree(
      id: id, name: id, branch: id, canDeleteWorktree: true,
      tabs: tabs ?? [tab("t1"), tab("t2"), tab("t3")],
      layout: RemoteClientLayout(
        mode: "tabsPerSplit", activeGroupId: "main",
        groups: [
          RemoteClientLayoutGroup(
            id: "main", focusedPaneId: "P2", zoomedPaneId: nil,
            tree: tree ?? .split(direction: "horizontal", ratio: 0.5, left: .pane("P1"), right: .pane("P2")))
        ],
        panes: [
          RemoteClientLayoutPane(id: "P1", tabIds: ["t1", "t2"], selectedTabId: "t2"),
          RemoteClientLayoutPane(id: "P2", tabIds: ["t3"], selectedTabId: "t3"),
        ] + extraPanes))
  }

  /// A store showing `list`, non-exhaustive: the tests check the fields they are about.
  private func shownStore(
    _ list: RemoteClientList = Self.list([Self.twoPane()]), session: FakeSession
  ) async -> TestStoreOf<RemoteClientFeature> {
    let store = Self.makeStore(session: session)
    store.exhaustivity = .off
    await store.send(.listChanged(list))
    return store
  }

  nonisolated private static func hostError(_ message: String, code: String?) -> RemoteClientRequestError {
    RemoteClientRequestError(kind: .host, message: message, code: code)
  }

  @Test func selectingATabIsLocalAndSendsNothing() async {
    let session = FakeSession()
    let store = await shownStore(session: session)
    #expect(store.state.selectedWorktreeID == "w1")
    await store.send(.tabSelected(paneID: "P1", tabID: "t1")) {
      $0.selections["w1"]?.selectedTabID["P1"] = "t1"
      $0.selections["w1"]?.focusedPaneID["main"] = "P1"
    }
    #expect(store.state.projection?.panes["P1"]?.selectedTabID == "t1")
    #expect(store.state.projection?.focusedPaneID == "P1")
    await store.finish()
    #expect(session.sent.value.isEmpty)
    #expect(session.visible.value.last == ["c-t1", "c-t3"])
  }

  @Test func aPushedListKeepsTheLocalTabChoice() async {
    let session = FakeSession()
    let store = await shownStore(session: session)
    await store.send(.tabSelected(paneID: "P1", tabID: "t1"))
    // The Mac adds a tab and still has t2 selected in P1.
    // P3 sits in the group's tree: the host never sends a pane outside it.
    let pushed = Self.list([
      Self.twoPane(
        tabs: [Self.tab("t1"), Self.tab("t2"), Self.tab("t3"), Self.tab("t4")],
        extraPanes: [RemoteClientLayoutPane(id: "P3", tabIds: ["t4"], selectedTabId: "t4")],
        tree: .split(
          direction: "horizontal", ratio: 0.5, left: .pane("P1"),
          right: .split(direction: "vertical", ratio: 0.5, left: .pane("P2"), right: .pane("P3"))))
    ])
    await store.send(.listChanged(pushed))
    #expect(store.state.projection?.panes["P1"]?.selectedTabID == "t1")
    #expect(store.state.selections["w1"]?.selectedTabID["P1"] == "t1")
    await store.finish()
    #expect(session.sent.value.isEmpty)
  }

  @Test func closingAWorkingTabAsksFirst() async {
    let session = FakeSession()
    let busy = Self.tab("t2", working: true)
    let store = await shownStore(
      Self.list([Self.twoPane(tabs: [Self.tab("t1"), busy, Self.tab("t3")])]), session: session)
    await store.send(.closeTabTapped(tabID: "t2")) {
      $0.alert = RemoteClientFeature.confirmCloseTabAlert(busy)
    }
    await store.finish()
    #expect(session.sent.value.isEmpty)
    await store.send(.alert(.presented(.confirmCloseTab("t2")))) {
      $0.alert = nil
      $0.busyRequests = ["tab.close:t2"]
    }
    await store.receive(\.requestFinished) {
      $0.busyRequests = []
    }
    await store.finish()
    #expect(session.sent.value == [Sent(type: "tab.close", fields: ["tabId": "t2"], ints: [:], timeout: .seconds(10))])
  }

  @Test func closingAnIdleTabSendsAtOnce() async {
    let session = FakeSession()
    let store = await shownStore(session: session)
    await store.send(.closeTabTapped(tabID: "t1")) {
      $0.busyRequests = ["tab.close:t1"]
    }
    await store.receive(\.requestFinished)
    await store.finish()
    #expect(store.state.alert == nil)
    #expect(session.sent.value == [Sent(type: "tab.close", fields: ["tabId": "t1"], ints: [:], timeout: .seconds(10))])
  }

  @Test func closingAPaneAlwaysAsks() async {
    let session = FakeSession()
    let store = await shownStore(session: session)
    await store.send(.closePaneTapped(paneID: "P2")) {
      $0.alert = RemoteClientFeature.confirmClosePaneAlert("P2")
    }
    await store.finish()
    #expect(session.sent.value.isEmpty)
    await store.send(.alert(.presented(.confirmClosePane("P2")))) {
      $0.alert = nil
    }
    await store.receive(\.requestFinished)
    await store.finish()
    #expect(
      session.sent.value == [Sent(type: "pane.close", fields: ["paneId": "P2"], ints: [:], timeout: .seconds(10))])
  }

  @Test func aSplitSendsTheTwoWayDirection() async {
    let session = FakeSession()
    let store = await shownStore(session: session)
    await store.send(.splitTapped(paneID: "P1", direction: .vertical)) {
      $0.busyRequests = ["pane.split:P1"]
    }
    await store.receive(\.requestFinished)
    await store.finish()
    #expect(
      session.sent.value == [
        Sent(type: "pane.split", fields: ["paneId": "P1", "direction": "vertical"], ints: [:], timeout: .seconds(15))
      ])
  }

  @Test func aNewTabCarriesThePaneAndItsGrid() async {
    let session = FakeSession()
    session.grids.setValue(["P1": RemoteAutoResize.Grid(columns: 120, rows: 40)])
    let store = await shownStore(session: session)
    await store.send(.newTabTapped(paneID: "P1"))
    await store.receive(\.requestFinished)
    // Without a pane: no `paneId`, and the focused pane's grid is not known yet.
    await store.send(.newTabTapped(paneID: nil))
    await store.receive(\.requestFinished)
    await store.finish()
    #expect(
      session.sent.value == [
        Sent(
          type: "tab.new", fields: ["worktreeId": "w1", "paneId": "P1"], ints: ["cols": 120, "rows": 40],
          timeout: .seconds(15)),
        Sent(type: "tab.new", fields: ["worktreeId": "w1"], ints: [:], timeout: .seconds(15)),
      ])
  }

  @Test func aNewTabFromAReplyIsSelectedWhenTheListHoldsIt() async {
    let session = FakeSession()
    session.reply.setValue({ _ in ["worktreeId": "w1", "tabId": "t4", "contentId": "c-t4"] })
    let store = await shownStore(session: session)
    await store.send(.newTabTapped(paneID: "P1"))
    await store.receive(\.requestFinished) {
      $0.pendingTabs = ["w1": "t4"]
    }
    // The next list holds the new tab in P1: it is selected there, and P1 is focused.
    var withNew = Self.twoPane(tabs: [Self.tab("t1"), Self.tab("t2"), Self.tab("t3"), Self.tab("t4")])
    withNew.layout?.panes[0].tabIds.append("t4")
    await store.send(.listChanged(Self.list([withNew]))) {
      $0.pendingTabs = [:]
    }
    #expect(store.state.projection?.panes["P1"]?.selectedTabID == "t4")
    #expect(store.state.projection?.focusedPaneID == "P1")
    await store.finish()
    #expect(session.visible.value.last == ["c-t4", "c-t3"])
  }

  @Test func aNewWorktreeNeedsANameAndSendsItTrimmed() async {
    let session = FakeSession()
    let store = await shownStore(session: session)
    await store.send(.newWorktreeTapped(repositoryID: "r")) {
      $0.newWorktree = RemoteClientFeature.NewWorktreePrompt(repositoryID: "r")
    }
    await store.send(.newWorktreeNameChanged("   ")) {
      $0.newWorktree?.name = "   "
    }
    await store.send(.newWorktreeConfirmed)
    await store.finish()
    #expect(store.state.newWorktree != nil)
    #expect(session.sent.value.isEmpty)
    await store.send(.newWorktreeNameChanged("  feature-x \n")) {
      $0.newWorktree?.name = "  feature-x \n"
    }
    await store.send(.newWorktreeConfirmed) {
      $0.newWorktree = nil
      $0.busyRequests = ["worktree.new:r"]
    }
    await store.receive(\.requestFinished)
    await store.finish()
    #expect(
      session.sent.value == [
        Sent(
          type: "worktree.new", fields: ["repositoryId": "r", "name": "feature-x"], ints: [:],
          timeout: .seconds(320))
      ])
  }

  @Test func aNewWorktreeIsSelectedWithItsTabWhenTheListHoldsIt() async {
    let session = FakeSession()
    session.reply.setValue({ _ in ["worktreeId": "w9", "name": "feature-x", "tabId": "t9", "contentId": "c-t9"] })
    let store = await shownStore(session: session)
    await store.send(.newWorktreeTapped(repositoryID: "r"))
    await store.send(.newWorktreeNameChanged("feature-x"))
    await store.send(.newWorktreeConfirmed)
    await store.receive(\.requestFinished) {
      $0.pendingWorktreeID = "w9"
      $0.pendingTabs = ["w9": "t9"]
    }
    #expect(store.state.selectedWorktreeID == "w1")
    let created = RemoteClientWorktree(id: "w9", name: "feature-x", tabs: [Self.tab("t9")])
    await store.send(.listChanged(Self.list([Self.twoPane(), created]))) {
      $0.selectedWorktreeID = "w9"
      $0.pendingWorktreeID = nil
      $0.pendingTabs = [:]
    }
    await store.finish()
    #expect(session.visible.value.last == ["c-t9"])
  }

  @Test func aDirtyDeleteShowsTheHostsMessage() async {
    let session = FakeSession()
    let message =
      "the worktree has uncommitted changes, untracked or ignored files (1): .env; "
      + "commit, stash or remove them on the Mac first"
    session.reply.setValue({ _ in throw Self.hostError(message, code: "worktree_dirty") })
    let store = await shownStore(session: session)
    await store.send(.deleteWorktreeTapped(worktreeID: "w1")) {
      $0.alert = RemoteClientFeature.confirmDeleteWorktreeAlert(Self.twoPane())
    }
    await store.finish()
    #expect(session.sent.value.isEmpty)
    await store.send(.alert(.presented(.confirmDeleteWorktree("w1"))))
    await store.receive(\.requestFinished) {
      $0.busyRequests = []
      $0.alert = RemoteClientFeature.failureAlert(title: "Could Not Delete the Worktree", message: message)
    }
    await store.finish()
    #expect(
      session.sent.value == [
        Sent(type: "worktree.delete", fields: ["worktreeId": "w1"], ints: [:], timeout: .seconds(310))
      ])
  }

  @Test func aLostConnectionDuringCreationSaysTheWorktreeMayStillAppear() async {
    let session = FakeSession()
    session.reply.setValue({ _ in
      throw RemoteClientRequestError(kind: .connectionLost, message: "closed", code: nil)
    })
    let store = await shownStore(session: session)
    await store.send(.newWorktreeTapped(repositoryID: "r"))
    await store.send(.newWorktreeNameChanged("feature-x"))
    await store.send(.newWorktreeConfirmed)
    await store.receive(\.requestFinished) {
      $0.alert = RemoteClientFeature.failureAlert(
        title: "Could Not Create the Worktree", message: "Connection lost; the worktree may still appear in the list")
    }
    await store.finish()
    #expect(session.sent.value.count == 1)
  }

  @Test func aTimedOutDeleteSaysTheWorktreeMayStillDisappear() async {
    let session = FakeSession()
    session.reply.setValue({ _ in
      throw RemoteClientRequestError(kind: .timeout, message: "late", code: nil)
    })
    let store = await shownStore(session: session)
    await store.send(.deleteWorktreeTapped(worktreeID: "w1"))
    await store.send(.alert(.presented(.confirmDeleteWorktree("w1"))))
    await store.receive(\.requestFinished) {
      $0.alert = RemoteClientFeature.failureAlert(
        title: "Could Not Delete the Worktree",
        message: "Connection lost; the worktree may still disappear from the list")
    }
    await store.finish()
    #expect(session.sent.value.count == 1)
  }

  @Test func aRequestInFlightDisablesItsButton() async {
    let session = FakeSession()
    let (gate, release) = AsyncStream.makeStream(of: Result<[String: String], RemoteClientRequestError>.self)
    session.reply.setValue({ _ in
      for await result in gate { return try result.get() }
      throw CancellationError()
    })
    let store = await shownStore(session: session)
    await store.send(.refreshTapped) {
      $0.busyRequests = ["worktrees.refresh"]
    }
    #expect(await settle { session.sent.value.count == 1 })
    // Pressed again while in flight: nothing more is sent.
    await store.send(.refreshTapped)
    release.yield(.success([:]))
    await store.receive(\.requestFinished) {
      $0.busyRequests = []
    }
    await store.finish()
    #expect(session.sent.value == [Sent(type: "worktrees.refresh", fields: [:], ints: [:], timeout: .seconds(70))])
  }

  @Test func aReplyForAMacTheWindowLeftIsIgnored() async {
    @Shared(.appStorage(RemoteClientFeature.selectedHostKey)) var saved: String?
    defer { $saved.withLock { $0 = nil } }
    let session = FakeSession()
    let store = await shownStore(session: session)
    await store.send(.hostPicked("b")) {
      $0.list = nil
      $0.busyRequests = []
    }
    await store.send(
      .requestFinished(key: "tab.close:t1", .failure(Self.hostError("no such tab", code: "tab_invalid"))))
    await store.finish()
    #expect(store.state.alert == nil)
  }

  @Test func theVisibleSetFollowsTheSelectedWorktreeAndTabs() async {
    let session = FakeSession()
    let single = RemoteClientWorktree(id: "w2", name: "two", tabs: [Self.tab("t5")])
    let store = await shownStore(Self.list([Self.twoPane(), single]), session: session)
    #expect(await settle { session.visible.value.last == ["c-t2", "c-t3"] })
    await store.send(.worktreeSelected("w2"))
    #expect(await settle { session.visible.value.last == ["c-t5"] })
    await store.send(.worktreeSelected("w1"))
    #expect(await settle { session.visible.value.last == ["c-t2", "c-t3"] })
    await store.send(.zoomToggled(paneID: "P1"))
    #expect(await settle { session.visible.value.last == ["c-t2"] })
    await store.send(.zoomToggled(paneID: "P1"))
    #expect(await settle { session.visible.value.last == ["c-t2", "c-t3"] })
    await store.finish()
  }

  @Test func aSelectedWorktreeThatVanishesFallsBackToTheFirst() async {
    let session = FakeSession()
    let store = await shownStore(Self.list([Self.twoPane("w1"), Self.twoPane("w2")]), session: session)
    await store.send(.worktreeSelected("w2"))
    await store.send(.tabSelected(paneID: "P1", tabID: "t1"))
    await store.send(.listChanged(Self.list([Self.twoPane("w1")]))) {
      $0.selectedWorktreeID = "w1"
    }
    #expect(store.state.selections["w2"] == nil)
    #expect(store.state.projection?.panes["P1"]?.selectedTabID == "t2")
    await store.finish()
    #expect(session.visible.value.last == ["c-t2", "c-t3"])
  }

  @Test func theFilterNarrowsTheSidebarOnly() async {
    let session = FakeSession()
    let list = Self.list([Self.twoPane("alpha"), Self.twoPane("beta")])
    let store = await shownStore(list, session: session)
    await store.send(.filterChanged("BET")) {
      $0.filterText = "BET"
      $0.sidebarSections = RemoteSidebarModel.sections(list, filter: "BET")
    }
    #expect(store.state.sidebarSections.flatMap(\.rows).map(\.id) == ["beta"])
    #expect(store.state.selectedWorktreeID == "alpha")
    await store.finish()
  }

  // MARK: - Review minors (task 11 fix round)

  typealias Outcome = Result<[String: String], RemoteClientRequestError>

  /// A reply the test releases by hand: the request waits on the returned stream.
  private func gated(_ session: FakeSession) -> AsyncStream<Outcome>.Continuation {
    let (gate, release) = AsyncStream.makeStream(of: Outcome.self)
    session.reply.setValue({ _ in
      for await result in gate { return try result.get() }
      throw CancellationError()
    })
    return release
  }

  @Test func aNewWorktreeDoesNotStealASelectionMadeWhileItRan() async {
    let session = FakeSession()
    let release = gated(session)
    let store = await shownStore(Self.list([Self.twoPane("w1"), Self.twoPane("w2")]), session: session)
    await store.send(.newWorktreeTapped(repositoryID: "r"))
    await store.send(.newWorktreeNameChanged("feature-x"))
    await store.send(.newWorktreeConfirmed)
    #expect(await settle { session.sent.value.count == 1 })
    // Picked while the request ran (up to 320 s).
    await store.send(.worktreeSelected("w2"))
    release.yield(.success(["worktreeId": "w9", "tabId": "t9"]))
    await store.receive(\.requestFinished)
    #expect(store.state.pendingWorktreeID == nil)
    #expect(store.state.newWorktreeOrigins.isEmpty)
    let created = RemoteClientWorktree(id: "w9", name: "feature-x", tabs: [Self.tab("t9")])
    await store.send(.listChanged(Self.list([Self.twoPane("w1"), Self.twoPane("w2"), created])))
    #expect(store.state.selectedWorktreeID == "w2")
    await store.finish()
  }

  @Test func aNewWorktreeFailureForgetsWhereItWasAsked() async {
    let session = FakeSession()
    session.reply.setValue({ _ in throw Self.hostError("no", code: nil) })
    let store = await shownStore(session: session)
    await store.send(.newWorktreeTapped(repositoryID: "r"))
    await store.send(.newWorktreeNameChanged("feature-x"))
    await store.send(.newWorktreeConfirmed)
    #expect(store.state.newWorktreeOrigins == ["worktree.new:r": "w1"])
    await store.receive(\.requestFinished)
    #expect(store.state.newWorktreeOrigins.isEmpty)
    await store.finish()
  }

  @Test func actionsTheMacDoesNotOfferDoNothing() async {
    let session = FakeSession()
    // A list that allows nothing: no create, no delete, no refresh.
    let list = RemoteClientList(
      repos: [RemoteClientRepository(id: "r", name: "repo", worktrees: [RemoteClientWorktree(id: "w1", name: "one")])])
    let store = await shownStore(list, session: session)
    await store.send(.newWorktreeTapped(repositoryID: "r"))
    #expect(store.state.newWorktree == nil)
    await store.send(.deleteWorktreeTapped(worktreeID: "w1"))
    #expect(store.state.alert == nil)
    await store.send(.refreshTapped)
    #expect(store.state.busyRequests.isEmpty)
    await store.finish()
    #expect(session.sent.value.isEmpty)
  }

  @Test func aNewTabInASecondPaneIsNotDroppedWhileTheFirstRuns() async {
    let session = FakeSession()
    // One gate per pane: a stream has one reader.
    let (gate1, release1) = AsyncStream.makeStream(of: Bool.self)
    let (gate2, release2) = AsyncStream.makeStream(of: Bool.self)
    session.reply.setValue({ sent in
      for await _ in sent.fields["paneId"] == "P1" ? gate1 : gate2 { return [:] }
      throw CancellationError()
    })
    let store = await shownStore(session: session)
    await store.send(.newTabTapped(paneID: "P1"))
    await store.send(.newTabTapped(paneID: "P2"))
    #expect(store.state.busyRequests == ["tab.new:w1|P1", "tab.new:w1|P2"])
    // The same pane again while its request runs: dropped.
    await store.send(.newTabTapped(paneID: "P1"))
    #expect(await settle { session.sent.value.count == 2 })
    release1.yield(true)
    release2.yield(true)
    await store.receive(\.requestFinished)
    await store.receive(\.requestFinished)
    #expect(store.state.busyRequests.isEmpty)
    #expect(Set(session.sent.value.map { $0.fields["paneId"] }) == ["P1", "P2"])
    #expect(session.sent.value.count == 2)
    await store.finish()
  }

  @Test func aRequestInFlightAcrossAMacSwitchChangesNothing() async {
    @Shared(.appStorage(RemoteClientFeature.selectedHostKey)) var saved: String?
    defer { $saved.withLock { $0 = nil } }
    let session = FakeSession()
    let release = gated(session)
    let store = await shownStore(session: session)
    await store.send(.newTabTapped(paneID: "P1"))
    #expect(await settle { session.sent.value.count == 1 })
    await store.send(.hostPicked("b"))
    // The old Mac's reply, from the cancelled wait or late: nothing happens.
    release.yield(.failure(Self.hostError("no such pane", code: "pane_invalid")))
    await store.send(.requestFinished(key: "tab.new:w1|P1", .failure(Self.hostError("no", code: nil))))
    await store.send(.requestFinished(key: "tab.new:w1|P1", .success(["worktreeId": "w1", "tabId": "t9"])))
    await store.finish()
    #expect(store.state.alert == nil)
    #expect(store.state.busyRequests.isEmpty)
    #expect(store.state.pendingTabs.isEmpty)
    #expect(store.state.pendingWorktreeID == nil)
  }

  @Test func aNewTabInAWorktreeWithoutLayoutSendsNoPaneId() async {
    let session = FakeSession()
    let plain = RemoteClientWorktree(id: "w1", name: "one", tabs: [Self.tab("t1")])
    let store = await shownStore(Self.list([plain]), session: session)
    // The synthetic `main` pane of a layout-less worktree is no real pane id.
    await store.send(.newTabTapped(paneID: "main"))
    await store.receive(\.requestFinished)
    await store.finish()
    #expect(
      session.sent.value == [Sent(type: "tab.new", fields: ["worktreeId": "w1"], ints: [:], timeout: .seconds(15))])
  }

  @Test func cancellingTheWorkingTabConfirmationSendsNothing() async {
    let session = FakeSession()
    let busy = Self.tab("t2", working: true)
    let store = await shownStore(
      Self.list([Self.twoPane(tabs: [Self.tab("t1"), busy, Self.tab("t3")])]), session: session)
    await store.send(.closeTabTapped(tabID: "t2"))
    #expect(store.state.alert != nil)
    await store.send(.alert(.dismiss))
    #expect(store.state.alert == nil)
    await store.finish()
    #expect(session.sent.value.isEmpty)
    #expect(store.state.busyRequests.isEmpty)
  }
}
