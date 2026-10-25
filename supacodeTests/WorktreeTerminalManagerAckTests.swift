import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import SupacodeSettingsFeature
import SupacodeSettingsShared
import Testing

@testable import supacode

/// Pins the manager's creation-ack contract: every `createTab` command emits
/// either the success pair (`tabCreated` + `surfaceCreated`) or a
/// `surfaceCreationFailed`, so a CLI or deeplink client can never strand on
/// the watchdog.
@MainActor
struct WorktreeTerminalManagerAckTests {
  private struct Harness {
    let manager: WorktreeTerminalManager
    let store: Store<AppFeature.State, AppFeature.Action>
    let worktree: Worktree
  }

  private func makeWorktree(id: String = "/tmp/repo/wt-ack") -> Worktree {
    Worktree(
      id: WorktreeID(id),
      name: URL(fileURLWithPath: id).lastPathComponent,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  /// Manager wired to a live store whose factory provisions inert content, so
  /// creation flows run end to end without spawning surfaces.
  private func makeHarness(
    storage: SettingsFileStorage = .inMemory(),
    defaults: UserDefaults = .inMemory,
    factory: LayoutContentFactory = LayoutContentFactory { request in
      InertTabContent(id: request.contentID, state: request.content)
    },
    killRemoteSession: @escaping @Sendable (RemoteHost, String) -> Void = { _, _ in }
  ) -> Harness {
    let worktree = makeWorktree()
    let manager = withDependencies {
      $0.settingsFileStorage = storage
      $0.defaultAppStorage = defaults
      $0.zmxClient = ZmxClient(
        executableURL: { nil },
        isBundled: { false },
        killSession: { _ in },
        killRemoteSession: { host, session in killRemoteSession(host, session) },
        listSessionsWithClients: { nil }
      )
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime())
    }
    let store = Store(
      initialState: AppFeature.State(
        repositories: RepositoriesFeature.State(),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      // One shared registry: the per-access `testValue` would otherwise hand
      // provision and lookup different runtimes.
      $0.contentRuntime = ContentRuntime()
      $0[LayoutContentFactory.self] = factory
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
    }
    manager.appStore = store
    return Harness(manager: manager, store: store, worktree: worktree)
  }

  /// One long-lived subscription per test: resubscribing between commands
  /// would strand one-shot events in the abandoned stream. Pulls creation
  /// events only; state replays (indicator counts, projections) pass through.
  private final class CreationEvents {
    // Tests pull sequentially on one task; the iterator only needs to escape
    // the actor so its mutating async `next` can run across suspensions.
    nonisolated(unsafe) private var iterator: AsyncStream<TerminalClient.Event>.AsyncIterator

    init(_ manager: WorktreeTerminalManager) {
      iterator = manager.eventStream().makeAsyncIterator()
    }

    nonisolated deinit {}

    func next(_ count: Int) async -> [TerminalClient.Event] {
      var events: [TerminalClient.Event] = []
      while events.count < count, let event = await iterator.next() {
        switch event {
        case .tabCreated, .surfaceCreated, .surfaceCreationFailed, .initialTabCreationFailed:
          events.append(event)
        default:
          continue
        }
      }
      return events
    }
  }

  @Test(.dependencies) func explicitIDCreateEmitsTheSuccessPair() async {
    let harness = makeHarness()
    let pump = CreationEvents(harness.manager)
    let id = UUID()
    harness.manager.handleCommand(
      .createTab(harness.worktree, runSetupScriptIfNew: false, id: id, focusing: false))

    let events = await pump.next(2)
    #expect(events.contains(.tabCreated(worktreeID: harness.worktree.id)))
    #expect(events.contains(.surfaceCreated(worktreeID: harness.worktree.id, id: id)))
    // The documented invariant: the initial surface ID equals the tab ID.
    let layout = harness.store.withState { $0.terminals.layouts[id: harness.worktree.id]?.layout }
    #expect(layout?.pane(containingTab: TabID(rawValue: id))?.tabs[id: TabID(rawValue: id)]?.content.id.rawValue == id)
  }

  @Test(.dependencies) func createWithoutAStoreDrainsTheAckAsFailure() async {
    let worktree = makeWorktree()
    let manager = withDependencies {
      $0.zmxClient = .noop
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime())
    }
    let pump = CreationEvents(manager)
    let id = UUID()
    manager.handleCommand(.createTab(worktree, runSetupScriptIfNew: false, id: id, focusing: false))

    let events = await pump.next(1)
    guard case .surfaceCreationFailed(let worktreeID, let attemptedID, _) = events.first else {
      Issue.record("Expected surfaceCreationFailed, got \(events)")
      return
    }
    #expect(worktreeID == worktree.id)
    #expect(attemptedID == id)
  }

  @Test(.dependencies) func ensureInitialTabWithoutAStoreEmitsInitialTabFailure() async {
    // The initial bootstrap emits its own failure event so only it settles the
    // worktree-new ack and the creation-progress overlay.
    let worktree = makeWorktree()
    let manager = withDependencies {
      $0.zmxClient = .noop
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime())
    }
    let pump = CreationEvents(manager)
    manager.handleCommand(.ensureInitialTab(worktree, runSetupScriptIfNew: false, focusing: false))

    let events = await pump.next(1)
    guard case .initialTabCreationFailed(let worktreeID, _) = events.first else {
      Issue.record("Expected initialTabCreationFailed, got \(events)")
      return
    }
    #expect(worktreeID == worktree.id)
  }

  @Test(.dependencies) func collidingContentIDCreateFailsInsteadOfFalselyAcking() async {
    let harness = makeHarness()
    let pump = CreationEvents(harness.manager)
    let first = UUID()
    harness.manager.handleCommand(
      .createTab(harness.worktree, runSetupScriptIfNew: false, id: first, focusing: false))
    _ = await pump.next(2)

    // Reusing the surface id of the EXISTING tab must refuse and say so, not
    // match the old content and ack a creation that never happened.
    harness.manager.handleCommand(
      .createTab(harness.worktree, runSetupScriptIfNew: false, id: first, focusing: false))
    let events = await pump.next(1)
    guard case .surfaceCreationFailed = events.first else {
      Issue.record("Expected surfaceCreationFailed, got \(events)")
      return
    }
  }

  @Test(.dependencies) func createWhoseSurfaceFailsDrainsTheAckAsFailureAndAddsNoTab() async {
    // Ghostty returning no surface (e.g. no active display) must fail the
    // create, not list and ack an empty tab.
    let harness = makeHarness(
      factory: LayoutContentFactory { request in
        TerminalContent(
          id: request.contentID,
          makeSurface: { _, _, _ in nil },
          initialState: TerminalContentState(workingDirectory: nil)
        )
      })
    let pump = CreationEvents(harness.manager)
    let id = UUID()
    harness.manager.handleCommand(
      .createTab(harness.worktree, runSetupScriptIfNew: false, id: id, focusing: false))

    let events = await pump.next(1)
    guard case .surfaceCreationFailed(let worktreeID, let attemptedID, _) = events.first else {
      Issue.record("Expected surfaceCreationFailed, got \(events)")
      return
    }
    #expect(worktreeID == harness.worktree.id)
    #expect(attemptedID == id)
    let layout = harness.store.withState { $0.terminals.layouts[id: harness.worktree.id]?.layout }
    #expect(layout?.pane(containingTab: TabID(rawValue: id)) == nil)
  }

  @Test(.dependencies) func ensureInitialTabOnAPopulatedLayoutStillAcks() async {
    let harness = makeHarness()
    let pump = CreationEvents(harness.manager)
    harness.manager.handleCommand(
      .createTab(harness.worktree, runSetupScriptIfNew: false, id: UUID(), focusing: false))
    _ = await pump.next(2)

    // A hydrated or already-bootstrapped layout resolves a waiting
    // worktree-new ack instead of stranding it until the watchdog.
    harness.manager.handleCommand(
      .ensureInitialTab(harness.worktree, runSetupScriptIfNew: false, focusing: false))
    let events = await pump.next(1)
    #expect(events.first == .tabCreated(worktreeID: harness.worktree.id))
  }

  private func singleTabLayout(contentID: UUID) -> PaneLayout {
    let paneID = PaneID()
    let tabID = TabID(rawValue: contentID)
    return PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [
            TabItem(
              id: tabID,
              title: "Restored",
              content: ContentSnapshot(
                id: ContentID(rawValue: contentID),
                state: .terminal(TerminalContentState(workingDirectory: nil))
              )
            )
          ],
          selectedTabID: tabID
        )
      ],
      focusedPaneID: paneID
    )
  }

  @Test(.dependencies) func removingADeletedWorktreesLayoutWorksWithoutAHost() async throws {
    // Layouts persist to UserDefaults now; signal each write so the async
    // incremental flush can be awaited without polling.
    let (fileWrites, writeSignal) = AsyncStream<LayoutsFile>.makeStream()
    let defaults = LayoutsSignalingDefaults { data in
      if let file = try? JSONDecoder().decode(LayoutsFile.self, from: data) {
        writeSignal.yield(file)
      }
    }
    let harness = makeHarness(defaults: defaults)
    let contentID = UUID()
    let layout = singleTabLayout(contentID: contentID)
    let record = LayoutRecord(layout: layout)
    defaults.seed(
      try JSONEncoder().encode(LayoutsFile(worktrees: [harness.worktree.id.rawValue: record]))
    )
    // Hydrated but never selected: no host exists for this worktree.
    harness.store.send(
      .terminals(
        .layoutsHydrated(LayoutsFile(worktrees: [harness.worktree.id.rawValue: record]))
      )
    )
    #expect(harness.store.withState { $0.terminals.layouts[id: harness.worktree.id] } != nil)

    harness.manager.handleCommand(
      .removeWorktreeLayout(worktreeID: harness.worktree.id, remoteHost: nil))

    // The in-memory layout detaches AND the persisted record goes with it;
    // this hostless-hydrated case is exactly the one roster prune cannot reach.
    #expect(harness.store.withState { $0.terminals.layouts[id: harness.worktree.id] } == nil)
    var writes = fileWrites.makeAsyncIterator()
    let written = await writes.next()
    #expect(written?.worktrees.isEmpty == true)
  }

  @Test(.dependencies) func removingAWorktreeLayoutRetractsItsSurfacesFromPresence() async {
    let harness = makeHarness()
    let contentID = UUID()
    let record = LayoutRecord(layout: singleTabLayout(contentID: contentID))
    // Subscribe before the command so the one-shot event isn't stranded.
    var iterator = harness.manager.eventStream().makeAsyncIterator()
    harness.store.send(
      .terminals(.layoutsHydrated(LayoutsFile(worktrees: [harness.worktree.id.rawValue: record]))))

    harness.manager.handleCommand(
      .removeWorktreeLayout(worktreeID: harness.worktree.id, remoteHost: nil))

    // The prune must retract the surface so AppFeature clears its agent presence.
    var closed: (worktreeID: Worktree.ID, ids: Set<UUID>)?
    while closed == nil, let event = await iterator.next() {
      if case .surfacesClosed(let worktreeID, let ids) = event {
        closed = (worktreeID, ids)
      }
    }
    #expect(closed?.worktreeID == harness.worktree.id)
    #expect(closed?.ids == [contentID])
  }

  @Test(.dependencies) func removingADeletedRemoteWorktreesLayoutKillsItsHostSessions() async {
    let (remoteKills, killSignal) = AsyncStream<(String, String)>.makeStream()
    let harness = makeHarness(killRemoteSession: { host, session in
      killSignal.yield((host.alias, session))
    })
    let contentID = UUID()
    harness.store.send(
      .terminals(
        .layoutsHydrated(
          LayoutsFile(
            worktrees: [
              harness.worktree.id.rawValue: LayoutRecord(layout: singleTabLayout(contentID: contentID))
            ]
          )
        )
      )
    )

    harness.manager.handleCommand(
      .removeWorktreeLayout(
        worktreeID: harness.worktree.id, remoteHost: RemoteHost(alias: "build-box")))

    var kills = remoteKills.makeAsyncIterator()
    let kill = await kills.next()
    #expect(kill?.0 == "build-box")
    #expect(kill?.1 == ZmxSessionID.make(surfaceID: contentID))
  }

  @Test(.dependencies) func anchoredCreateLandsInTheAnchorsPane() async {
    let harness = makeHarness()
    let pump = CreationEvents(harness.manager)
    let anchor = UUID()
    harness.manager.handleCommand(
      .createTab(harness.worktree, runSetupScriptIfNew: false, id: anchor, focusing: false))
    _ = await pump.next(2)

    let added = UUID()
    harness.manager.handleCommand(
      .createTab(
        harness.worktree, runSetupScriptIfNew: false, id: added, focusing: false, anchor: anchor))
    _ = await pump.next(2)

    let layout = harness.store.withState { $0.terminals.layouts[id: harness.worktree.id]?.layout }
    let anchorPane = layout?.tab(containingContent: ContentID(rawValue: anchor))?.pane
    #expect(anchorPane?.tabs[id: TabID(rawValue: added)] != nil)
  }

  // MARK: - Splits in Each Tab.

  /// Creates `count` tabs in one pane (the first, then anchored ones), returns their ids in
  /// creation order, and leaves the layout in Tabs in Each Split mode.
  private func makeTabs(_ count: Int, harness: Harness, pump: CreationEvents) async -> [UUID] {
    var ids: [UUID] = []
    for _ in 0..<count {
      let id = UUID()
      harness.manager.handleCommand(
        .createTab(
          harness.worktree, runSetupScriptIfNew: false, id: id, focusing: false, anchor: ids.first))
      _ = await pump.next(2)
      ids.append(id)
    }
    return ids
  }

  private func convertToSplitPerTab(_ harness: Harness) {
    harness.store.send(
      .terminals(
        .layouts(.element(id: harness.worktree.id, action: .convertMode(to: .splitPerTab)))))
  }

  private func layoutState(_ harness: Harness) -> LayoutFeature.State? {
    harness.store.withState { $0.terminals.layouts[id: harness.worktree.id] }
  }

  /// The group holding a tab, in strip order (1-based).
  private func groupIndex(ofTab tabID: UUID, in layout: PaneLayout) -> Int? {
    layout.pane(containingTab: TabID(rawValue: tabID))
      .flatMap { layout.groupID(containingPane: $0.id) }
      .flatMap { layout.groupIndex(of: $0) }
  }

  @Test(.dependencies) func anchoredCreateInSplitPerTabCreatesAGroupAndAcksWithMatchingIDs() async {
    let harness = makeHarness()
    let pump = CreationEvents(harness.manager)
    let anchor = UUID()
    harness.manager.handleCommand(
      .createTab(harness.worktree, runSetupScriptIfNew: false, id: anchor, focusing: false))
    _ = await pump.next(2)
    convertToSplitPerTab(harness)

    let added = UUID()
    harness.manager.handleCommand(
      .createTab(
        harness.worktree, runSetupScriptIfNew: false, id: added, focusing: false, anchor: anchor))
    let events = await pump.next(2)

    #expect(events.contains(.tabCreated(worktreeID: harness.worktree.id)))
    #expect(events.contains(.surfaceCreated(worktreeID: harness.worktree.id, id: added)))
    guard let layout = layoutState(harness)?.layout,
      let anchorPane = layout.pane(containingTab: TabID(rawValue: anchor))
    else {
      Issue.record("Expected a layout holding the anchor tab")
      return
    }
    // A new group, not a tab in the anchor's pane; TabID == ContentID still holds.
    #expect(layout.groupOrder.count == 2)
    #expect(anchorPane.tabs.count == 1)
    let addedTab = layout.pane(containingTab: TabID(rawValue: added))?.tabs[id: TabID(rawValue: added)]
    #expect(addedTab?.content.id.rawValue == added)
    // Not selected: the anchor's group stays active.
    #expect(layout.activeGroupID == layout.groupID(containingPane: anchorPane.id))
  }

  @Test(.dependencies) func selectedAnchoredCreateInSplitPerTabActivatesTheNewGroup() async {
    let harness = makeHarness()
    let pump = CreationEvents(harness.manager)
    let anchor = UUID()
    harness.manager.handleCommand(
      .createTab(harness.worktree, runSetupScriptIfNew: false, id: anchor, focusing: false))
    _ = await pump.next(2)
    convertToSplitPerTab(harness)

    let added = UUID()
    harness.manager.handleCommand(
      .createTab(
        harness.worktree, runSetupScriptIfNew: false, id: added, focusing: true, anchor: anchor))
    _ = await pump.next(2)

    guard let layout = layoutState(harness)?.layout else {
      Issue.record("Expected a layout")
      return
    }
    #expect(layout.groupOrder.count == 2)
    #expect(groupIndex(ofTab: added, in: layout) == 2)
    #expect(layout.focusedPaneID == layout.pane(containingTab: TabID(rawValue: added))?.id)
  }

  @Test(.dependencies) func openFilePlacementTabLandsAsANewGroupInSplitPerTab() async {
    let harness = makeHarness()
    let pump = CreationEvents(harness.manager)
    let first = UUID()
    harness.manager.handleCommand(
      .createTab(harness.worktree, runSetupScriptIfNew: false, id: first, focusing: false))
    _ = await pump.next(2)
    convertToSplitPerTab(harness)
    let paneID = layoutState(harness)?.layout.focusedPaneID
    // A zoomed leaf always places as a tab in that pane; `openFileWithScript` then
    // anchors the create on the pane token, exactly as here.
    guard case .tab(let paneToken) = Self.zoomedPlacement(paneID) else {
      Issue.record("Expected a tab placement")
      return
    }

    harness.manager.handleCommand(
      .createTab(
        harness.worktree, runSetupScriptIfNew: false, id: UUID(), focusing: true, anchor: paneToken))
    _ = await pump.next(2)

    let layout = layoutState(harness)?.layout
    #expect(layout?.groupOrder.count == 2)
    #expect(layout?.panes.allSatisfy { $0.tabs.count == 1 } == true)
  }

  private static func zoomedPlacement(_ paneID: PaneID?) -> WorktreeTerminalManager.OpenFilePlacement? {
    WorktreeTerminalManager.openFilePlacement(
      zoomedLeaf: paneID, leafCount: 1, topRightLeaf: paneID, focusedPane: paneID, hasRoomForSplit: true)
  }

  @Test(.dependencies) func listFieldsAreAbsentInTabsPerSplit() async {
    let harness = makeHarness()
    let pump = CreationEvents(harness.manager)
    _ = await makeTabs(2, harness: harness, pump: pump)
    let worktreeID = harness.worktree.id.rawValue

    let tabs = harness.manager.listTabs(worktreeID: worktreeID) ?? []
    let panes = harness.manager.listPanes(worktreeID: worktreeID) ?? []

    // v2 entries are byte-for-byte what they were: only `id` and `focused`.
    #expect(tabs.count == 2)
    #expect(tabs.allSatisfy { Set($0.keys).isSubset(of: ["id", "focused"]) })
    #expect(panes.count == 1)
    #expect(panes.allSatisfy { Set($0.keys).isSubset(of: ["id", "focused"]) })
  }

  @Test(.dependencies) func listTabsAndPanesCarryGroupFieldsInSplitPerTab() async {
    let harness = makeHarness()
    let pump = CreationEvents(harness.manager)
    let ids = await makeTabs(3, harness: harness, pump: pump)
    convertToSplitPerTab(harness)
    let worktreeID = harness.worktree.id.rawValue
    guard let layout = layoutState(harness)?.layout else {
      Issue.record("Expected a layout")
      return
    }

    let tabs = harness.manager.listTabs(worktreeID: worktreeID) ?? []
    let panes = harness.manager.listPanes(worktreeID: worktreeID) ?? []

    #expect(tabs.count == 3)
    for id in ids {
      let entry = tabs.first { $0["id"] == id.uuidString }
      #expect(entry?["group"] == groupIndex(ofTab: id, in: layout).map(String.init))
      #expect(entry?["activeGroup"] == nil)
    }
    #expect(Set(tabs.compactMap { $0["group"] }) == ["1", "2", "3"])
    #expect(tabs.filter { $0["focused"] == "1" }.count == 1)

    #expect(panes.count == 3)
    #expect(Set(panes.compactMap { $0["group"] }) == ["1", "2", "3"])
    // Only the active group's pane carries `activeGroup`.
    let active = panes.filter { $0["activeGroup"] == "1" }
    #expect(active.count == 1)
    #expect(active.first?["group"] == layout.activeGroupID.flatMap { layout.groupIndex(of: $0) }.map(String.init))
    #expect(active.first?["id"] == layout.focusedPaneID?.rawValue.uuidString)
  }

  @Test(.dependencies) func selectTabAtIndexSelectsGroupsInSplitPerTab() async {
    let harness = makeHarness()
    let pump = CreationEvents(harness.manager)
    let ids = await makeTabs(3, harness: harness, pump: pump)
    convertToSplitPerTab(harness)

    harness.manager.handleCommand(.selectTabAtIndex(harness.worktree, index: 3))
    var layout = layoutState(harness)?.layout
    #expect(layout?.focusedPaneID == layout?.pane(containingTab: TabID(rawValue: ids[2]))?.id)
    #expect(layout.flatMap { l in l.activeGroupID.flatMap { l.groupIndex(of: $0) } } == 3)

    harness.manager.handleCommand(.selectTabAtIndex(harness.worktree, index: 2))
    layout = layoutState(harness)?.layout
    #expect(layout?.focusedPaneID == layout?.pane(containingTab: TabID(rawValue: ids[1]))?.id)

    // Past the end clamps to the last group, Ghostty goto_tab style.
    harness.manager.handleCommand(.selectTabAtIndex(harness.worktree, index: 9))
    layout = layoutState(harness)?.layout
    #expect(layout.flatMap { l in l.activeGroupID.flatMap { l.groupIndex(of: $0) } } == 3)
  }

  @Test(.dependencies) func selectRelativeTabWalksGroupsAndWrapsInSplitPerTab() async {
    let harness = makeHarness()
    let pump = CreationEvents(harness.manager)
    _ = await makeTabs(3, harness: harness, pump: pump)
    convertToSplitPerTab(harness)
    func activeIndex() -> Int? {
      layoutState(harness).flatMap { state in
        state.layout.activeGroupID.flatMap { state.layout.groupIndex(of: $0) }
      }
    }
    #expect(activeIndex() == 1)

    harness.manager.handleCommand(.selectRelativeTab(harness.worktree, forward: true))
    #expect(activeIndex() == 2)
    harness.manager.handleCommand(.selectRelativeTab(harness.worktree, forward: true))
    #expect(activeIndex() == 3)
    harness.manager.handleCommand(.selectRelativeTab(harness.worktree, forward: true))
    #expect(activeIndex() == 1)
    harness.manager.handleCommand(.selectRelativeTab(harness.worktree, forward: false))
    #expect(activeIndex() == 3)
  }

  @Test(.dependencies) func selectTabAtIndexStillWalksThePanesStripInTabsPerSplit() async {
    let harness = makeHarness()
    let pump = CreationEvents(harness.manager)
    let ids = await makeTabs(3, harness: harness, pump: pump)

    harness.manager.handleCommand(.selectTabAtIndex(harness.worktree, index: 3))

    let layout = layoutState(harness)?.layout
    #expect(layout?.activeGroupID == nil)
    #expect(layout?.panes.first?.selectedTabID == TabID(rawValue: ids[2]))
  }

  @Test(.dependencies) func canMoveTabToNewSplitIsFalseInSplitPerTab() async {
    let harness = makeHarness()
    let pump = CreationEvents(harness.manager)
    let ids = await makeTabs(2, harness: harness, pump: pump)
    // Two tabs in one pane: movable in Tabs in Each Split.
    #expect(harness.manager.canMoveTabToNewSplit(worktreeID: harness.worktree.id, tabID: ids[1]))

    convertToSplitPerTab(harness)

    #expect(!harness.manager.canMoveTabToNewSplit(worktreeID: harness.worktree.id, tabID: ids[0]))
    #expect(!harness.manager.canMoveTabToNewSplit(worktreeID: harness.worktree.id, tabID: ids[1]))
  }
}

/// In-memory `UserDefaults` that signals every layouts blob write, so a test can
/// await the incremental writer's async flush without polling. `seed(_:)` primes
/// the store without signaling.
private nonisolated final class LayoutsSignalingDefaults: UserDefaults, @unchecked Sendable {
  private let lock = NSLock()
  private var store: [String: Data] = [:]
  private let onWrite: @Sendable (Data) -> Void

  init(onWrite: @escaping @Sendable (Data) -> Void) {
    self.onWrite = onWrite
    super.init(suiteName: "layouts-signal-\(UUID().uuidString)")!
  }

  func seed(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    store[LayoutsFile.userDefaultsKey] = data
  }

  override func data(forKey defaultName: String) -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return store[defaultName]
  }

  override func set(_ value: Any?, forKey defaultName: String) {
    lock.lock()
    store[defaultName] = value as? Data
    lock.unlock()
    guard defaultName == LayoutsFile.userDefaultsKey, let data = value as? Data else { return }
    onWrite(data)
  }
}
