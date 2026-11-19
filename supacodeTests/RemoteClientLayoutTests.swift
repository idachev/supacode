import Foundation
import Testing

@testable import supacode

struct RemoteClientLayoutTests {
  // MARK: - Fixtures

  private static func tab(_ id: String, title: String? = nil, focused: Bool = false) -> RemoteClientTab {
    RemoteClientTab(id: id, contentId: "c-\(id)", title: title ?? "title-\(id)", focused: focused)
  }

  private static func pane(_ id: String, _ tabIds: [String], selected: String? = nil) -> RemoteClientLayoutPane {
    RemoteClientLayoutPane(id: id, tabIds: tabIds, selectedTabId: selected)
  }

  private static func group(
    _ id: String, _ tree: RemoteClientLayoutNode, focused: String? = nil, zoomed: String? = nil
  ) -> RemoteClientLayoutGroup {
    RemoteClientLayoutGroup(id: id, focusedPaneId: focused, zoomedPaneId: zoomed, tree: tree)
  }

  private static func split(_ left: RemoteClientLayoutNode, _ right: RemoteClientLayoutNode)
    -> RemoteClientLayoutNode
  {
    .split(direction: "horizontal", ratio: 0.5, left: left, right: right)
  }

  private static func worktree(layout: RemoteClientLayout?, tabs: [RemoteClientTab]) -> RemoteClientWorktree {
    RemoteClientWorktree(id: "w1", tabs: tabs, layout: layout)
  }

  /// Panes P1 [t1, t2 selected t2] and P2 [t3] side by side in the one group `main`, focused P2.
  private static func twoPaneWorktree(
    focused: String? = "P2", zoomed: String? = nil, tabs: [RemoteClientTab]? = nil
  ) -> RemoteClientWorktree {
    worktree(
      layout: RemoteClientLayout(
        mode: "tabsPerSplit", activeGroupId: "main",
        groups: [group("main", split(.pane("P1"), .pane("P2")), focused: focused, zoomed: zoomed)],
        panes: [pane("P1", ["t1", "t2"], selected: "t2"), pane("P2", ["t3"], selected: "t3")]),
      tabs: tabs ?? [tab("t1"), tab("t2"), tab("t3")])
  }

  // MARK: - Projection

  @Test func theFirstProjectionTakesTheHostsChoices() {
    var selection = RemoteLocalSelection()
    let projection = RemoteLayoutProjection.project(Self.twoPaneWorktree(), selection: &selection)

    #expect(selection.selectedTabID == ["P1": "t2", "P2": "t3"])
    #expect(selection.focusedPaneID == ["main": "P2"])
    #expect(selection.zoomedPaneID.isEmpty)
    #expect(selection.activeGroupID == "main")
    #expect(projection.mode == "tabsPerSplit")
    #expect(projection.activeGroupID == "main")
    #expect(projection.groups.map(\.id) == ["main"])
    #expect(projection.groups.first?.focusedPaneID == "P2")
    #expect(projection.panes["P1"]?.selectedTabID == "t2")
    #expect(projection.panes["P1"]?.tabs.map(\.id) == ["t1", "t2"])
    #expect(projection.panes["P2"]?.selectedTabID == "t3")
  }

  @Test func aSeededSelectedTabTheHostLeavesNilIsThePanesFirstTab() {
    let worktree = Self.worktree(
      layout: RemoteClientLayout(
        mode: "tabsPerSplit", activeGroupId: "main",
        groups: [Self.group("main", .pane("P1"), focused: "P1")],
        panes: [Self.pane("P1", ["t1", "t2"])]),
      tabs: [Self.tab("t1"), Self.tab("t2")])
    var selection = RemoteLocalSelection()
    let projection = RemoteLayoutProjection.project(worktree, selection: &selection)

    #expect(projection.panes["P1"]?.selectedTabID == "t1")
    #expect(selection.selectedTabID == ["P1": "t1"])
  }

  @Test func aLocalTabChoiceSurvivesAPushedList() {
    var selection = RemoteLocalSelection(selectedTabID: ["P1": "t1"])
    let projection = RemoteLayoutProjection.project(Self.twoPaneWorktree(), selection: &selection)

    #expect(projection.panes["P1"]?.selectedTabID == "t1")
    #expect(projection.panes["P2"]?.selectedTabID == "t3")
    #expect(selection.selectedTabID == ["P1": "t1", "P2": "t3"])
  }

  @Test func aChoiceOfAClosedTabFallsBackToTheHosts() {
    var selection = RemoteLocalSelection(selectedTabID: ["P1": "gone"])
    let projection = RemoteLayoutProjection.project(Self.twoPaneWorktree(), selection: &selection)

    #expect(projection.panes["P1"]?.selectedTabID == "t2")
    #expect(selection.selectedTabID["P1"] == "t2")

    // A choice of a tab that exists, but in another pane, is no choice either.
    var elsewhere = RemoteLocalSelection(selectedTabID: ["P1": "t3"])
    let again = RemoteLayoutProjection.project(Self.twoPaneWorktree(), selection: &elsewhere)
    #expect(again.panes["P1"]?.selectedTabID == "t2")
  }

  @Test func aLocalZoomAndFocusAreKeptWhileThePaneExists() {
    var selection = RemoteLocalSelection(focusedPaneID: ["main": "P1"], zoomedPaneID: ["main": "P1"])
    let projection = RemoteLayoutProjection.project(Self.twoPaneWorktree(), selection: &selection)

    #expect(projection.groups.first?.focusedPaneID == "P1")
    #expect(projection.groups.first?.zoomedPaneID == "P1")
    #expect(selection.focusedPaneID == ["main": "P1"])
    #expect(selection.zoomedPaneID == ["main": "P1"])

    // P1 loses its tabs: the pane is gone, so focus and zoom come from the host again.
    let afterClose = Self.twoPaneWorktree(
      focused: "P2", zoomed: nil,
      tabs: [Self.tab("t3")])
    let reseeded = RemoteLayoutProjection.project(afterClose, selection: &selection)
    #expect(reseeded.groups.first?.tree == .pane("P2"))
    #expect(reseeded.groups.first?.focusedPaneID == "P2")
    #expect(reseeded.groups.first?.zoomedPaneID == nil)
    #expect(selection.focusedPaneID == ["main": "P2"])
    #expect(selection.zoomedPaneID.isEmpty)
    #expect(selection.selectedTabID == ["P2": "t3"])
  }

  @Test func aHostZoomIsSeededWhenTheLaptopHasNone() {
    var selection = RemoteLocalSelection()
    let projection = RemoteLayoutProjection.project(Self.twoPaneWorktree(zoomed: "P1"), selection: &selection)

    #expect(projection.groups.first?.zoomedPaneID == "P1")
    #expect(selection.zoomedPaneID == ["main": "P1"])
  }

  @Test func splitPerTabKeepsTheLocalActiveGroup() {
    let worktree = Self.worktree(
      layout: RemoteClientLayout(
        mode: "splitPerTab", activeGroupId: "G1",
        groups: [
          Self.group("G1", .pane("P1"), focused: "P1"),
          Self.group("G2", Self.split(.pane("P2"), .pane("P3")), focused: "P3"),
        ],
        panes: [
          Self.pane("P1", ["t1"], selected: "t1"),
          Self.pane("P2", ["t2"], selected: "t2"),
          Self.pane("P3", ["t3a", "t3b"], selected: "t3a"),
        ]),
      tabs: [Self.tab("t1"), Self.tab("t2"), Self.tab("t3a", title: "claude"), Self.tab("t3b")])

    var seeded = RemoteLocalSelection()
    let first = RemoteLayoutProjection.project(worktree, selection: &seeded)
    #expect(first.activeGroupID == "G1")
    #expect(first.mode == "splitPerTab")
    #expect(first.groups.map(\.id) == ["G1", "G2"])
    #expect(first.groups.map(\.title) == ["title-t1", "claude"])

    var selection = RemoteLocalSelection(activeGroupID: "G2")
    let projection = RemoteLayoutProjection.project(worktree, selection: &selection)
    #expect(projection.activeGroupID == "G2")
    #expect(selection.activeGroupID == "G2")
    #expect(projection.visibleContentIDs == ["c-t2", "c-t3a"])

    // A local active group the host no longer has falls back to the host's.
    var gone = RemoteLocalSelection(activeGroupID: "G9", focusedPaneID: ["G9": "P9"])
    let fallback = RemoteLayoutProjection.project(worktree, selection: &gone)
    #expect(fallback.activeGroupID == "G1")
    #expect(gone.activeGroupID == "G1")
    #expect(gone.focusedPaneID["G9"] == nil)
  }

  @Test func aWorktreeWithoutLayoutIsOnePaneOfAllTabs() {
    let worktree = Self.worktree(layout: nil, tabs: [Self.tab("t1"), Self.tab("t2", focused: true)])
    var selection = RemoteLocalSelection()
    let projection = RemoteLayoutProjection.project(worktree, selection: &selection)

    #expect(projection.mode == "tabsPerSplit")
    #expect(projection.groups.map(\.id) == ["main"])
    #expect(projection.groups.first?.tree == .pane("main"))
    #expect(projection.activeGroupID == "main")
    #expect(projection.panes.count == 1)
    #expect(projection.panes["main"]?.tabs.map(\.id) == ["t1", "t2"])
    #expect(projection.panes["main"]?.selectedTabID == "t2")
    #expect(projection.visibleContentIDs == ["c-t2"])

    // Nothing focused: the first tab; and a local choice wins over the host's focus.
    var plain = RemoteLocalSelection()
    let none = RemoteLayoutProjection.project(
      Self.worktree(layout: nil, tabs: [Self.tab("t1"), Self.tab("t2")]), selection: &plain)
    #expect(none.panes["main"]?.selectedTabID == "t1")
    var local = RemoteLocalSelection(selectedTabID: ["main": "t1"])
    let kept = RemoteLayoutProjection.project(worktree, selection: &local)
    #expect(kept.panes["main"]?.selectedTabID == "t1")

    // No tabs at all: nothing to draw.
    var empty = RemoteLocalSelection()
    let nothing = RemoteLayoutProjection.project(Self.worktree(layout: nil, tabs: []), selection: &empty)
    #expect(nothing.groups.isEmpty)
    #expect(nothing.activeGroupID == nil)
    #expect(nothing.panes.isEmpty)
    #expect(nothing.visibleContentIDs.isEmpty)
  }

  @Test func unknownTabIdsAreSkippedAndAnEmptyPaneLeavesTheTree() {
    let worktree = Self.worktree(
      layout: RemoteClientLayout(
        mode: "tabsPerSplit", activeGroupId: "main",
        groups: [
          Self.group(
            "main", Self.split(.pane("P1"), Self.split(.pane("P2"), .pane("P3"))), focused: "P2"),
          Self.group("dead", .pane("P4")),
        ],
        panes: [
          Self.pane("P1", ["t1", "ghost"], selected: "ghost"),
          Self.pane("P2", ["ghost2"], selected: "ghost2"),
          Self.pane("P3", ["t3"], selected: "t3"),
          Self.pane("P4", []),
        ]),
      tabs: [Self.tab("t1"), Self.tab("t3")])
    var selection = RemoteLocalSelection()
    let projection = RemoteLayoutProjection.project(worktree, selection: &selection)

    #expect(projection.panes["P1"]?.tabs.map(\.id) == ["t1"])
    #expect(projection.panes["P1"]?.selectedTabID == "t1")
    #expect(projection.panes["P2"] == nil)
    #expect(projection.panes["P4"] == nil)
    #expect(projection.groups.map(\.id) == ["main"])
    #expect(projection.groups.first?.tree == Self.split(.pane("P1"), .pane("P3")))
    // The host's focus is on the dropped pane: the first pane of the tree takes it.
    #expect(projection.groups.first?.focusedPaneID == "P1")
    #expect(selection.focusedPaneID == ["main": "P1"])
    #expect(selection.selectedTabID == ["P1": "t1", "P3": "t3"])
  }

  @Test func visibleContentsAreTheSelectedTabsOfTheActiveGroup() {
    let worktree = Self.worktree(
      layout: RemoteClientLayout(
        mode: "splitPerTab", activeGroupId: "G1",
        groups: [
          Self.group("G1", Self.split(.pane("P1"), .pane("P2")), focused: "P1"),
          Self.group("G2", .pane("P3")),
        ],
        panes: [
          Self.pane("P1", ["t1", "t2"], selected: "t2"),
          Self.pane("P2", ["t3"], selected: "t3"),
          Self.pane("P3", ["t4"], selected: "t4"),
        ]),
      tabs: [Self.tab("t1"), Self.tab("t2"), Self.tab("t3"), Self.tab("t4")])

    var selection = RemoteLocalSelection()
    let plain = RemoteLayoutProjection.project(worktree, selection: &selection)
    #expect(plain.visibleContentIDs == ["c-t2", "c-t3"])

    selection.zoomedPaneID["G1"] = "P2"
    let zoomed = RemoteLayoutProjection.project(worktree, selection: &selection)
    #expect(zoomed.visibleContentIDs == ["c-t3"])

    selection.zoomedPaneID["G1"] = nil
    selection.selectedTabID["P1"] = "t1"
    selection.activeGroupID = "G2"
    let other = RemoteLayoutProjection.project(worktree, selection: &selection)
    #expect(other.visibleContentIDs == ["c-t4"])
  }

  // MARK: - Attached set

  @Test func newVisibleContentsAttachAndHiddenOnesLingerThirtySeconds() {
    var set = RemoteAttachedSet()
    let start = ContinuousClock.now
    #expect(set.update(visible: ["a", "b"], now: start) == .init(attach: ["a", "b"], detach: []))
    #expect(set.nextExpiry == nil)
    #expect(set.update(visible: ["b"], now: start + .seconds(29)) == .init(attach: [], detach: []))
    #expect(set.nextExpiry == start + .seconds(59))
    #expect(set.update(visible: ["b"], now: start + .seconds(59)) == .init(attach: [], detach: ["a"]))
    #expect(set.nextExpiry == nil)
  }

  @Test func aContentShownAgainInTimeIsNotReattached() {
    var set = RemoteAttachedSet()
    let start = ContinuousClock.now
    _ = set.update(visible: ["a"], now: start)
    _ = set.update(visible: [], now: start + .seconds(5))
    #expect(set.update(visible: ["a"], now: start + .seconds(10)) == .init(attach: [], detach: []))
    // Its linger starts over when it is hidden again.
    _ = set.update(visible: [], now: start + .seconds(20))
    #expect(set.nextExpiry == start + .seconds(50))
    #expect(set.update(visible: [], now: start + .seconds(49)) == .init(attach: [], detach: []))
    #expect(set.update(visible: [], now: start + .seconds(50)) == .init(attach: [], detach: ["a"]))
  }

  @Test func beyondSixteenTheLeastRecentlyVisibleGoes() {
    var set = RemoteAttachedSet()
    let start = ContinuousClock.now
    for index in 0..<RemoteAttachedSet.limit {
      let step = set.update(visible: ["c\(index)"], now: start + .seconds(index))
      #expect(step == .init(attach: ["c\(index)"], detach: []))
    }
    let step = set.update(visible: ["c16"], now: start + .seconds(16))
    #expect(step == .init(attach: ["c16"], detach: ["c0"]))
  }

  @Test func theLimitNeverDetachesAVisibleContent() {
    var set = RemoteAttachedSet()
    let start = ContinuousClock.now
    let visible = (0...RemoteAttachedSet.limit).map { "v\($0)" }
    let step = set.update(visible: visible, now: start)
    #expect(step.attach == visible)
    #expect(step.detach.isEmpty)

    // One goes hidden: the set is over the limit, so that one goes at once, before its linger ends.
    let rest = Array(visible.dropFirst())
    #expect(set.update(visible: rest, now: start + .seconds(1)) == .init(attach: [], detach: ["v0"]))
    // Everything left is visible, so another visible content is attached and nothing is detached.
    let next = set.update(visible: rest + ["w"], now: start + .seconds(2))
    #expect(next == .init(attach: ["w"], detach: []))
  }

  @Test func lingerEndsAreDetachedSortedAndOverflowComesAfterThem() {
    var set = RemoteAttachedSet()
    let start = ContinuousClock.now
    _ = set.update(visible: ["b", "a", "c"], now: start)
    _ = set.update(visible: [], now: start + .seconds(1))
    let step = set.update(visible: ["d"], now: start + .seconds(31))
    #expect(step == .init(attach: ["d"], detach: ["a", "b", "c"]))
  }
}
