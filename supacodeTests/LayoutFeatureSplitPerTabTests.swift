import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import SupacodeSettingsShared
import Testing

@testable import supacode

/// Split-per-tab branches of `LayoutFeature`: the live mode conversion, group
/// switching and creation, the owning-tree rules for parked panes, and the
/// group-aware collapse. Ids minted by the reducer come from `.incrementing`,
/// so the fixture's conversion is deterministic.
@MainActor
struct LayoutFeatureSplitPerTabTests {
  // MARK: - Fixture.

  private static let worktreeID = WorktreeID("/tmp/layout-split-per-tab")
  private nonisolated static let seedState = TerminalContentState(workingDirectory: "/tmp/layout-split-per-tab")

  private nonisolated static func tab(_ title: String) -> TabItem {
    TabItem(id: TabID(), title: title, content: ContentSnapshot(id: ContentID(), state: .terminal(seedState)))
  }

  private static func spec(select: Bool = true, title: String = "New") -> NewTabSpec {
    NewTabSpec(
      tabID: TabID(),
      contentID: ContentID(),
      title: title,
      content: .terminal(seedState),
      geometry: .fallback,
      select: select
    )
  }

  /// Two panes split right: A holds a1 (selected), a2, a3; B holds b1 (selected),
  /// b2. Focus is on A. v2 → SPT then mints, in order: group 1 = G(0); a2 →
  /// P(1), G(2); a3 → P(3), G(4); b2 → P(5), G(6).
  private struct Fixture {
    let paneA = PaneID()
    let paneB = PaneID()
    let tabsA = ["a1", "a2", "a3"].map(LayoutFeatureSplitPerTabTests.tab)
    let tabsB = ["b1", "b2"].map(LayoutFeatureSplitPerTabTests.tab)

    var layout: PaneLayout {
      let tree = (try? SplitTree(view: paneA).inserting(view: paneB, at: paneA, direction: .right)) ?? SplitTree()
      return PaneLayout(
        tree: tree,
        panes: [
          Pane(id: paneA, tabs: IdentifiedArray(uniqueElements: tabsA), selectedTabID: tabsA[0].id),
          Pane(id: paneB, tabs: IdentifiedArray(uniqueElements: tabsB), selectedTabID: tabsB[0].id),
        ],
        focusedPaneID: paneA
      )
    }

    var allTabs: [TabItem] { tabsA + tabsB }

    static let group1 = PaneGroupID(rawValue: UUID(0))
    static let groupA2 = PaneGroupID(rawValue: UUID(2))
    static let groupA3 = PaneGroupID(rawValue: UUID(4))
    static let groupB2 = PaneGroupID(rawValue: UUID(6))
    static let paneA2 = PaneID(rawValue: UUID(1))
    static let paneA3 = PaneID(rawValue: UUID(3))
    static let paneB2 = PaneID(rawValue: UUID(5))
  }

  private struct Bundle {
    let store: TestStoreOf<LayoutFeature>
    let runtime: ContentRuntime
    let kills: LockIsolated<[ContentID]>

    var layout: PaneLayout { store.state.layout }
  }

  /// A store over `layout` (v2 shape) whose runtime already hosts every content,
  /// with a recording session killer.
  private func makeStore(layout: PaneLayout, preserveZoom: Bool = false) -> Bundle {
    let runtime = ContentRuntime()
    for contentID in layout.allContentIDs {
      _ = runtime.provision(
        InertTabContent(id: contentID, state: .terminal(Self.seedState)), at: .fallback)
    }
    let kills = LockIsolated<[ContentID]>([])
    let store = TestStore(initialState: LayoutFeature.State(id: Self.worktreeID, layout: layout)) {
      LayoutFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.contentRuntime = runtime
      $0[SplitZoomPolicy.self] = SplitZoomPolicy(preservesZoomOnNavigation: { preserveZoom })
      $0.layoutContentFactory = LayoutContentFactory(
        make: { request in InertTabContent(id: request.contentID, state: request.content) }
      )
      $0[ContentSessionKiller.self] = ContentSessionKiller(
        kill: { contentID, _ in kills.withValue { $0.append(contentID) } }
      )
    }
    store.exhaustivity = .off
    return Bundle(store: store, runtime: runtime, kills: kills)
  }

  /// The fixture converted to split per tab.
  private func makeSplitPerTab(_ fixture: Fixture = Fixture(), preserveZoom: Bool = false) async -> Bundle {
    let bundle = makeStore(layout: fixture.layout, preserveZoom: preserveZoom)
    await bundle.store.send(.convertMode(to: .splitPerTab))
    #expect(bundle.store.state.mode == .splitPerTab)
    #expect(bundle.layout.isConsistent(for: .splitPerTab))
    return bundle
  }

  private static func tabIDs(_ layout: PaneLayout) -> Set<TabID> {
    Set(layout.panes.flatMap { $0.tabs.ids })
  }

  // MARK: - Conversion.

  @Test func convertModeBothWaysKillsNothingAndKeepsEveryID() async {
    let fixture = Fixture()
    let bundle = await makeSplitPerTab(fixture)
    let original = fixture.layout
    var layout = bundle.layout
    #expect(layout.groupOrder == [Fixture.group1, Fixture.groupA2, Fixture.groupA3, Fixture.groupB2])
    #expect(layout.activeGroupID == Fixture.group1)
    #expect(layout.parkedGroups.count == 3)
    #expect(layout.tree == original.tree)
    #expect(layout.focusedPaneID == fixture.paneA)
    #expect(layout.panes[id: Fixture.paneA2]?.tabs.ids.elements == [fixture.tabsA[1].id])
    #expect(Self.tabIDs(layout) == Self.tabIDs(original))
    #expect(Set(layout.allContentIDs) == Set(original.allContentIDs))

    await bundle.store.send(.convertMode(to: .tabsPerSplit))
    layout = bundle.layout
    #expect(bundle.store.state.mode == .tabsPerSplit)
    #expect(layout.activeGroupID == nil)
    #expect(layout.parkedGroups.isEmpty)
    #expect(layout.groupOrder.isEmpty)
    #expect(layout.isConsistent(for: .tabsPerSplit))
    #expect(layout.focusedPaneID == fixture.paneA)
    // The home pane keeps its visible tab.
    #expect(layout.panes[id: fixture.paneA]?.selectedTabID == fixture.tabsA[0].id)
    #expect(Self.tabIDs(layout) == Self.tabIDs(original))
    #expect(Set(layout.allContentIDs) == Set(original.allContentIDs))

    await bundle.store.finish()
    #expect(bundle.kills.value.isEmpty)
    #expect(bundle.runtime.pendingKill.isEmpty)
    for contentID in original.allContentIDs {
      #expect(bundle.runtime.content(for: contentID) != nil)
    }
  }

  @Test func convertModeIsIdempotent() async {
    let bundle = makeStore(layout: Fixture().layout)
    bundle.store.exhaustivity = .on
    // Already v2: nothing changes and nothing is minted.
    await bundle.store.send(.convertMode(to: .tabsPerSplit))
    bundle.store.exhaustivity = .off
    await bundle.store.send(.convertMode(to: .splitPerTab))
    let converted = bundle.store.state
    await bundle.store.send(.convertMode(to: .splitPerTab))
    #expect(bundle.store.state == converted)
  }

  @Test func convertingAnEmptyLayoutOnlyFlipsTheMode() async {
    let bundle = makeStore(layout: PaneLayout())
    await bundle.store.send(.convertMode(to: .splitPerTab))
    #expect(bundle.store.state.mode == .splitPerTab)
    #expect(bundle.layout == PaneLayout())
  }

  @Test func dissolvedWindowedPaneLeavesWindowMode() async {
    let bundle = await makeSplitPerTab()
    await bundle.store.send(.enterWindowMode(paneID: Fixture.paneA2))
    #expect(bundle.store.state.windowedPaneIDs == [Fixture.paneA2])
    await bundle.store.send(.convertMode(to: .tabsPerSplit))
    #expect(bundle.store.state.windowedPaneIDs.isEmpty)
    #expect(bundle.kills.value.isEmpty)
  }

  @Test func windowedPaneKeepsItsWindowIntoSplitPerTab() async {
    let fixture = Fixture()
    let bundle = makeStore(layout: fixture.layout)
    await bundle.store.send(.enterWindowMode(paneID: fixture.paneB))
    await bundle.store.send(.convertMode(to: .splitPerTab))
    #expect(bundle.store.state.windowedPaneIDs == [fixture.paneB])
  }

  @Test(.dependencies) func pendingAlertOnADissolvedPaneIsCancelled() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseTab = .always }
    defer { $settingsFile.withLock { $0.global.confirmCloseTab = GlobalSettings.default.confirmCloseTab } }
    let fixture = Fixture()
    let bundle = await makeSplitPerTab(fixture)
    await bundle.store.send(.contentRequestedClose(content: fixture.tabsA[1].content.id, scope: .tab))
    #expect(bundle.store.state.alertPaneID == Fixture.paneA2)
    #expect(bundle.store.state.alert != nil)
    await bundle.store.send(.convertMode(to: .tabsPerSplit))
    #expect(bundle.store.state.alert == nil)
    #expect(bundle.store.state.alertPaneID == nil)
    #expect(Self.tabIDs(bundle.layout) == Self.tabIDs(fixture.layout))
  }

  // MARK: - Group switching.

  @Test func selectGroupSwapsTheActiveTree() async {
    let fixture = Fixture()
    let bundle = await makeSplitPerTab(fixture)
    let group1Tree = bundle.layout.tree
    await bundle.store.send(.selectGroup(id: Fixture.groupA3))
    #expect(bundle.layout.activeGroupID == Fixture.groupA3)
    #expect(bundle.layout.focusedPaneID == Fixture.paneA3)
    #expect(bundle.layout.tree == SplitTree(view: Fixture.paneA3))
    #expect(bundle.layout.parkedGroups[id: Fixture.group1]?.tree == group1Tree)
    #expect(bundle.layout.parkedGroups[id: Fixture.group1]?.focusedPaneID == fixture.paneA)
    // Strip order never changes on a switch.
    #expect(bundle.layout.groupOrder == [Fixture.group1, Fixture.groupA2, Fixture.groupA3, Fixture.groupB2])
    let switched = bundle.store.state
    await bundle.store.send(.selectGroup(id: Fixture.groupA3))
    #expect(bundle.store.state == switched)
    // An unknown group is ignored.
    await bundle.store.send(.selectGroup(id: PaneGroupID(rawValue: UUID())))
    #expect(bundle.store.state == switched)
    #expect(bundle.kills.value.isEmpty)
  }

  @Test func groupActionsAreIgnoredInTabsPerSplit() async {
    let bundle = makeStore(layout: Fixture().layout)
    bundle.store.exhaustivity = .on
    await bundle.store.send(.selectGroup(id: Fixture.group1))
    await bundle.store.send(.moveGroup(id: Fixture.group1, toIndex: 1))
    await bundle.store.send(.newGroup(spec: Self.spec()))
    #expect(bundle.runtime.pendingKill.isEmpty)
  }

  @Test func selectingOrFocusingAParkedTabSwitchesGroup() async {
    let fixture = Fixture()
    let bundle = await makeSplitPerTab(fixture)
    await bundle.store.send(.selectTab(id: fixture.tabsB[1].id))
    #expect(bundle.layout.activeGroupID == Fixture.groupB2)
    #expect(bundle.layout.focusedPaneID == Fixture.paneB2)
    await bundle.store.send(.contentRequestedFocus(content: fixture.tabsA[2].content.id))
    #expect(bundle.layout.activeGroupID == Fixture.groupA3)
    #expect(bundle.layout.focusedPaneID == Fixture.paneA3)
    await bundle.store.send(.focusPane(.pane(fixture.paneB)))
    #expect(bundle.layout.activeGroupID == Fixture.group1)
    #expect(bundle.layout.focusedPaneID == fixture.paneB)
    #expect(bundle.layout.isConsistent(for: .splitPerTab))
  }

  // MARK: - New groups.

  @Test func newTabCreatesASelectedGroupAfterTheActiveOne() async {
    let fixture = Fixture()
    let bundle = await makeSplitPerTab(fixture)
    await bundle.store.send(.selectGroup(id: Fixture.groupA2))
    let spec = Self.spec()
    // The pane anchor is ignored; the conversion used UUID(0)...UUID(6).
    await bundle.store.send(.newTab(inPane: fixture.paneB, spec: spec))
    let newPane = PaneID(rawValue: UUID(7))
    let newGroup = PaneGroupID(rawValue: UUID(8))
    #expect(
      bundle.layout.groupOrder == [Fixture.group1, Fixture.groupA2, newGroup, Fixture.groupA3, Fixture.groupB2])
    #expect(bundle.layout.activeGroupID == newGroup)
    #expect(bundle.layout.focusedPaneID == newPane)
    #expect(bundle.layout.panes[id: newPane]?.tabs.ids.elements == [spec.tabID].compactMap { $0 })
    #expect(bundle.layout.panes[id: fixture.paneB]?.tabs.count == 1)
    #expect(bundle.layout.isConsistent(for: .splitPerTab))
  }

  @Test func backgroundNewTabAppendsAGroupWithoutSwitching() async {
    let fixture = Fixture()
    let bundle = await makeSplitPerTab(fixture)
    await bundle.store.send(.newTab(inPane: fixture.paneA, spec: Self.spec(select: false)))
    let newGroup = PaneGroupID(rawValue: UUID(8))
    #expect(bundle.layout.groupOrder.last == newGroup)
    #expect(bundle.layout.activeGroupID == Fixture.group1)
    #expect(bundle.layout.focusedPaneID == fixture.paneA)
    #expect(bundle.layout.parkedGroups[id: newGroup]?.focusedPaneID == PaneID(rawValue: UUID(7)))
    #expect(bundle.layout.isConsistent(for: .splitPerTab))
  }

  @Test func contentRequestedNewTabCreatesAGroupAfterTheActiveOne() async {
    let fixture = Fixture()
    let bundle = await makeSplitPerTab(fixture)
    let before = bundle.layout
    await bundle.store.send(.contentRequestedNewTab(content: fixture.tabsA[0].content.id))
    let layout = bundle.layout
    #expect(layout.groupOrder.count == before.groupOrder.count + 1)
    #expect(layout.groupOrder[0] == Fixture.group1)
    #expect(layout.activeGroupID == layout.groupOrder[1])
    // The source pane keeps its one tab; the new tab sits alone in a new pane.
    #expect(layout.panes[id: fixture.paneA]?.tabs.count == 1)
    #expect(layout.focusedPaneID.flatMap { layout.panes[id: $0]?.tabs.count } == 1)
    #expect(layout.isConsistent(for: .splitPerTab))
  }

  @Test func newGroupOnAnEmptyLayoutBootstrapsGroupOne() async {
    let bundle = makeStore(layout: PaneLayout())
    await bundle.store.send(.convertMode(to: .splitPerTab))
    let spec = Self.spec(select: false)
    await bundle.store.send(.newGroup(spec: spec))
    // Explicit spec ids mint nothing, so the pane is UUID(0) and the group UUID(1).
    let paneID = PaneID(rawValue: UUID(0))
    let groupID = PaneGroupID(rawValue: UUID(1))
    #expect(bundle.layout.tree == SplitTree(view: paneID))
    #expect(bundle.layout.focusedPaneID == paneID)
    #expect(bundle.layout.activeGroupID == groupID)
    #expect(bundle.layout.groupOrder == [groupID])
    #expect(bundle.layout.parkedGroups.isEmpty)
    #expect(bundle.layout.isConsistent(for: .splitPerTab))
  }

  // MARK: - Parked trees.

  @Test func backgroundSplitOfAParkedPaneKeepsTheActiveGroup() async {
    let fixture = Fixture()
    let bundle = await makeSplitPerTab(fixture)
    await bundle.store.send(
      .splitPane(id: Fixture.paneA2, direction: .right, spec: Self.spec(select: false)))
    let newPane = PaneID(rawValue: UUID(7))
    #expect(bundle.layout.activeGroupID == Fixture.group1)
    #expect(bundle.layout.focusedPaneID == fixture.paneA)
    #expect(bundle.layout.parkedGroups[id: Fixture.groupA2]?.tree.leaves() == [Fixture.paneA2, newPane])
    #expect(bundle.layout.parkedGroups[id: Fixture.groupA2]?.focusedPaneID == Fixture.paneA2)
    #expect(bundle.layout.isConsistent(for: .splitPerTab))
  }

  @Test func zoomStaysPerGroupAcrossSwitches() async {
    let fixture = Fixture()
    let bundle = await makeSplitPerTab(fixture)
    await bundle.store.send(.toggleZoom(paneID: fixture.paneB))
    let zoomed = bundle.layout.tree.zoomed
    #expect(zoomed == bundle.layout.tree.find(id: fixture.paneB.rawValue))
    await bundle.store.send(.selectGroup(id: Fixture.groupA2))
    #expect(bundle.layout.tree.zoomed == nil)
    await bundle.store.send(.selectGroup(id: Fixture.group1))
    #expect(bundle.layout.tree.zoomed == zoomed)
    #expect(bundle.layout.focusedPaneID == fixture.paneB)
  }

  /// Gives the parked group A2 a second pane and zooms that pane while the
  /// group is parked again; returns the second pane.
  private func zoomParkedSplit(_ bundle: Bundle) async -> PaneID {
    await bundle.store.send(
      .splitPane(id: Fixture.paneA2, direction: .right, spec: Self.spec(select: false)))
    let second = PaneID(rawValue: UUID(7))
    await bundle.store.send(.selectGroup(id: Fixture.groupA2))
    await bundle.store.send(.toggleZoom(paneID: second))
    await bundle.store.send(.selectGroup(id: Fixture.group1))
    #expect(bundle.layout.parkedGroups[id: Fixture.groupA2]?.tree.zoomed != nil)
    return second
  }

  @Test(arguments: [false, true])
  func toggleZoomOnAParkedPaneActivatesItsGroupAndZoomsIt(preserveZoom: Bool) async {
    let bundle = await makeSplitPerTab(preserveZoom: preserveZoom)
    _ = await zoomParkedSplit(bundle)
    await bundle.store.send(.toggleZoom(paneID: Fixture.paneA2))
    let layout = bundle.layout
    #expect(layout.activeGroupID == Fixture.groupA2)
    #expect(layout.focusedPaneID == Fixture.paneA2)
    #expect(layout.tree.zoomed == layout.tree.find(id: Fixture.paneA2.rawValue))
    #expect(layout.tree.zoomed != nil)
    #expect(layout.isConsistent(for: .splitPerTab))
  }

  @Test func toggleZoomOnALoneParkedPaneActivatesItsGroupWithoutZooming() async {
    let bundle = await makeSplitPerTab()
    await bundle.store.send(.toggleZoom(paneID: Fixture.paneA3))
    // The group switches first; a lone leaf then has nothing to zoom.
    #expect(bundle.layout.activeGroupID == Fixture.groupA3)
    #expect(bundle.layout.focusedPaneID == Fixture.paneA3)
    #expect(bundle.layout.tree.zoomed == nil)
    #expect(bundle.layout.isConsistent(for: .splitPerTab))
  }

  @Test func enterWindowModeOnAZoomedParkedPaneClearsThatGroupsZoom() async {
    let bundle = await makeSplitPerTab()
    let second = await zoomParkedSplit(bundle)
    await bundle.store.send(.enterWindowMode(paneID: second))
    #expect(bundle.store.state.windowedPaneIDs == [second])
    #expect(bundle.layout.parkedGroups[id: Fixture.groupA2]?.tree.zoomed == nil)
    #expect(bundle.layout.activeGroupID == Fixture.group1)
    #expect(bundle.layout.isConsistent(for: .splitPerTab))
  }

  // MARK: - Closing.

  @Test func closingTheLastPaneOfAParkedGroupRemovesTheGroup() async {
    let fixture = Fixture()
    let bundle = await makeSplitPerTab(fixture)
    await bundle.store.send(.closePane(id: Fixture.paneA3))
    await bundle.store.finish()
    #expect(bundle.layout.groupOrder == [Fixture.group1, Fixture.groupA2, Fixture.groupB2])
    #expect(bundle.layout.parkedGroups[id: Fixture.groupA3] == nil)
    #expect(bundle.layout.activeGroupID == Fixture.group1)
    #expect(bundle.layout.focusedPaneID == fixture.paneA)
    #expect(bundle.kills.value == [fixture.tabsA[2].content.id])
    #expect(bundle.layout.isConsistent(for: .splitPerTab))
  }

  @Test func closingAParkedFocusedPaneRetargetsThatGroupsFocus() async {
    let bundle = await makeSplitPerTab()
    await bundle.store.send(
      .splitPane(id: Fixture.paneA2, direction: .right, spec: Self.spec(select: false)))
    let second = PaneID(rawValue: UUID(7))
    await bundle.store.send(.closePane(id: Fixture.paneA2))
    #expect(bundle.layout.parkedGroups[id: Fixture.groupA2]?.tree == SplitTree(view: second))
    #expect(bundle.layout.parkedGroups[id: Fixture.groupA2]?.focusedPaneID == second)
    #expect(bundle.layout.activeGroupID == Fixture.group1)
    #expect(bundle.layout.isConsistent(for: .splitPerTab))
  }

  @Test func closingTheActiveGroupsLastPaneActivatesThePreviousElseTheNextGroup() async {
    let fixture = Fixture()
    let bundle = await makeSplitPerTab(fixture)
    await bundle.store.send(.selectGroup(id: Fixture.groupA3))
    await bundle.store.send(.closePane(id: Fixture.paneA3))
    #expect(bundle.layout.activeGroupID == Fixture.groupA2)
    #expect(bundle.layout.focusedPaneID == Fixture.paneA2)
    #expect(bundle.layout.isConsistent(for: .splitPerTab))
    // The first group has no previous one, so its neighbour after it wins.
    await bundle.store.send(.selectGroup(id: Fixture.group1))
    await bundle.store.send(.closePane(id: fixture.paneA))
    // A surviving pane of the active group keeps the group and takes focus.
    #expect(bundle.layout.activeGroupID == Fixture.group1)
    #expect(bundle.layout.focusedPaneID == fixture.paneB)
    await bundle.store.send(.closePane(id: fixture.paneB))
    #expect(bundle.layout.activeGroupID == Fixture.groupA2)
    #expect(bundle.layout.groupOrder == [Fixture.groupA2, Fixture.groupB2])
    #expect(bundle.layout.isConsistent(for: .splitPerTab))
  }

  @Test func closingTheLastGroupEmptiesTheLayout() async {
    let paneID = PaneID()
    let only = Self.tab("only")
    let layout = PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [Pane(id: paneID, tabs: [only], selectedTabID: only.id)],
      focusedPaneID: paneID
    )
    let bundle = makeStore(layout: layout)
    await bundle.store.send(.convertMode(to: .splitPerTab))
    #expect(bundle.layout.groupOrder == [PaneGroupID(rawValue: UUID(0))])
    await bundle.store.send(.closeTab(id: only.id))
    await bundle.store.finish()
    #expect(bundle.layout.panes.isEmpty)
    #expect(bundle.layout.tree.isEmpty)
    #expect(bundle.layout.focusedPaneID == nil)
    #expect(bundle.layout.activeGroupID == nil)
    #expect(bundle.layout.groupOrder.isEmpty)
    #expect(bundle.kills.value == [only.content.id])
  }

  @Test(.dependencies, arguments: [ConfirmCloseTabMode.always, .never, .busy])
  func closeOnAGroupsOnlyPaneClosesThatGroup(mode: ConfirmCloseTabMode) async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseTab = mode }
    defer { $settingsFile.withLock { $0.global.confirmCloseTab = GlobalSettings.default.confirmCloseTab } }
    let fixture = Fixture()
    let bundle = await makeSplitPerTab(fixture)
    await bundle.store.send(.selectGroup(id: Fixture.groupB2))
    let tab = fixture.tabsB[1]
    await bundle.store.send(.contentRequestedClose(content: tab.content.id, scope: .tab))
    if bundle.store.state.alert != nil {
      await bundle.store.send(.alert(.presented(.confirmClose(tabs: [tab.id]))))
    }
    await bundle.store.finish()
    #expect(bundle.layout.groupOrder == [Fixture.group1, Fixture.groupA2, Fixture.groupA3])
    // The previous group in strip order takes over.
    #expect(bundle.layout.activeGroupID == Fixture.groupA3)
    #expect(bundle.kills.value == [tab.content.id])
    #expect(bundle.layout.isConsistent(for: .splitPerTab))
  }

  @Test(.dependencies) func closeOtherTabsHasNothingToCloseInSplitPerTab() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseTab = .never }
    defer { $settingsFile.withLock { $0.global.confirmCloseTab = GlobalSettings.default.confirmCloseTab } }
    let fixture = Fixture()
    let bundle = await makeSplitPerTab(fixture)
    let before = bundle.store.state
    await bundle.store.send(.contentRequestedClose(content: fixture.tabsA[0].content.id, scope: .otherTabs))
    await bundle.store.send(.contentRequestedClose(content: fixture.tabsA[0].content.id, scope: .tabsToTheRight))
    #expect(bundle.store.state == before)
    #expect(bundle.kills.value.isEmpty)
  }

  // MARK: - Strip order and refusals.

  @Test func moveGroupClampsTheIndex() async {
    let bundle = await makeSplitPerTab()
    await bundle.store.send(.moveGroup(id: Fixture.groupB2, toIndex: -5))
    #expect(bundle.layout.groupOrder == [Fixture.groupB2, Fixture.group1, Fixture.groupA2, Fixture.groupA3])
    await bundle.store.send(.moveGroup(id: Fixture.groupB2, toIndex: 99))
    #expect(bundle.layout.groupOrder == [Fixture.group1, Fixture.groupA2, Fixture.groupA3, Fixture.groupB2])
    await bundle.store.send(.moveGroup(id: Fixture.group1, toIndex: 2))
    #expect(bundle.layout.groupOrder == [Fixture.groupA2, Fixture.groupA3, Fixture.group1, Fixture.groupB2])
    // Order is not selection.
    #expect(bundle.layout.activeGroupID == Fixture.group1)
    let before = bundle.store.state
    await bundle.store.send(.moveGroup(id: PaneGroupID(rawValue: UUID()), toIndex: 0))
    #expect(bundle.store.state == before)
  }

  @Test func tabMovesAreRefusedInSplitPerTab() async {
    let fixture = Fixture()
    let bundle = await makeSplitPerTab(fixture)
    let before = bundle.store.state
    let moved = fixture.tabsA[0]
    await bundle.store.send(.moveTab(id: moved.id, toPane: fixture.paneB, index: 0))
    await bundle.store.send(.moveTabToSplit(id: moved.id, anchor: fixture.paneB, direction: .down))
    await bundle.store.send(.moveTabToSpanningSplit(id: moved.id, anchor: fixture.paneB, direction: .down))
    await bundle.store.send(.contentRequestedMoveTab(content: moved.content.id, amount: 1))
    #expect(bundle.store.state == before)
  }

  @Test func contentRequestedGotoTabTargetsGroups() async {
    let fixture = Fixture()
    let bundle = await makeSplitPerTab(fixture)
    let source = fixture.tabsA[0].content.id
    await bundle.store.send(.contentRequestedGotoTab(content: source, target: .next))
    #expect(bundle.layout.activeGroupID == Fixture.groupA2)
    await bundle.store.send(.contentRequestedGotoTab(content: source, target: .last))
    #expect(bundle.layout.activeGroupID == Fixture.groupB2)
    // Next wraps from the last group to the first.
    await bundle.store.send(.contentRequestedGotoTab(content: source, target: .next))
    #expect(bundle.layout.activeGroupID == Fixture.group1)
    await bundle.store.send(.contentRequestedGotoTab(content: source, target: .previous))
    #expect(bundle.layout.activeGroupID == Fixture.groupB2)
    await bundle.store.send(.contentRequestedGotoTab(content: source, target: .position(3)))
    #expect(bundle.layout.activeGroupID == Fixture.groupA3)
    // Positions clamp to the strip; zero is ignored.
    await bundle.store.send(.contentRequestedGotoTab(content: source, target: .position(42)))
    #expect(bundle.layout.activeGroupID == Fixture.groupB2)
    await bundle.store.send(.contentRequestedGotoTab(content: source, target: .position(0)))
    #expect(bundle.layout.activeGroupID == Fixture.groupB2)
    #expect(bundle.layout.isConsistent(for: .splitPerTab))
  }
}
