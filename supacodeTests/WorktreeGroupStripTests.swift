import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

/// The split-per-tab group strip's view logic, driven with plain layouts so
/// the view bodies stay free of derived state.
@MainActor
struct WorktreeGroupStripTests {
  private static func tab(title: String) -> TabItem {
    TabItem(
      id: TabID(),
      title: title,
      content: ContentSnapshot(
        id: ContentID(),
        state: .terminal(TerminalContentState(workingDirectory: "/tmp/group-strip"))
      )
    )
  }

  private static func pane(_ tab: TabItem) -> Pane {
    Pane(id: PaneID(), tabs: IdentifiedArray(uniqueElements: [tab]), selectedTabID: tab.id)
  }

  /// Three groups in strip order: the active one splits two panes (the second
  /// focused), the other two hold one pane each.
  private struct Fixture {
    let layout: PaneLayout
    let groups: [PaneGroupID]
    let tabs: [TabItem]
  }

  private static func fixture() throws -> Fixture {
    let tabs = ["Left", "Right", "Second", "Third"].map { Self.tab(title: $0) }
    let panes = tabs.map { Self.pane($0) }
    let groups = (0..<3).map { _ in PaneGroupID(rawValue: UUID()) }
    let activeTree = try SplitTree(view: panes[0].id).inserting(
      view: panes[1].id, at: panes[0].id, direction: .right
    )
    let layout = PaneLayout(
      tree: activeTree,
      panes: IdentifiedArray(uniqueElements: panes),
      focusedPaneID: panes[1].id,
      activeGroupID: groups[0],
      parkedGroups: [
        PaneGroup(id: groups[1], tree: SplitTree(view: panes[2].id), focusedPaneID: panes[2].id),
        PaneGroup(id: groups[2], tree: SplitTree(view: panes[3].id), focusedPaneID: panes[3].id),
      ],
      groupOrder: groups
    )
    return Fixture(layout: layout, groups: groups, tabs: tabs)
  }

  @Test func groupShowsItsFocusedPanesSelectedTab() throws {
    let fixture = try Self.fixture()
    #expect(WorktreeGroupStrip.displayedTab(ofGroup: fixture.groups[0], in: fixture.layout)?.id == fixture.tabs[1].id)
    #expect(WorktreeGroupStrip.displayedTab(ofGroup: fixture.groups[2], in: fixture.layout)?.id == fixture.tabs[3].id)
    #expect(WorktreeGroupStrip.displayedTab(ofGroup: PaneGroupID(rawValue: UUID()), in: fixture.layout) == nil)
  }

  @Test func rightwardDropCompensatesForTheRemovedSource() throws {
    let fixture = try Self.fixture()
    // The first group's tab dropped on the third tab lands before it: index 1.
    let target = WorktreeGroupStrip.moveTarget(forDraggedTab: fixture.tabs[1].id, droppedAt: 2, in: fixture.layout)
    #expect(target?.id == fixture.groups[0])
    #expect(target?.toIndex == 1)
    // Dropped past the last tab: the end.
    let end = WorktreeGroupStrip.moveTarget(forDraggedTab: fixture.tabs[0].id, droppedAt: 3, in: fixture.layout)
    #expect(end?.id == fixture.groups[0])
    #expect(end?.toIndex == 2)
  }

  @Test func leftwardDropLandsBeforeTheTargetTab() throws {
    let fixture = try Self.fixture()
    let target = WorktreeGroupStrip.moveTarget(forDraggedTab: fixture.tabs[3].id, droppedAt: 0, in: fixture.layout)
    #expect(target?.id == fixture.groups[2])
    #expect(target?.toIndex == 0)
  }

  @Test func dropThatKeepsTheGroupInPlaceOrComesFromElsewhereMovesNothing() throws {
    let fixture = try Self.fixture()
    #expect(WorktreeGroupStrip.moveTarget(forDraggedTab: fixture.tabs[2].id, droppedAt: 1, in: fixture.layout) == nil)
    #expect(WorktreeGroupStrip.moveTarget(forDraggedTab: fixture.tabs[2].id, droppedAt: 2, in: fixture.layout) == nil)
    #expect(WorktreeGroupStrip.moveTarget(forDraggedTab: TabID(), droppedAt: 0, in: fixture.layout) == nil)
  }

  @Test func tooltipNamesSelectTabWithItsChordForTheFirstNine() {
    #expect(WorktreeGroupStrip.tooltip(title: "zsh", slot: 1, chord: "⌘2") == "zsh — Select Tab 2 (⌘2)")
    #expect(WorktreeGroupStrip.tooltip(title: "zsh", slot: 8, chord: nil) == "zsh — Select Tab 9")
    #expect(WorktreeGroupStrip.tooltip(title: "zsh", slot: 9, chord: nil) == "zsh")
  }
}
