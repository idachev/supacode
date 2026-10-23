import Dependencies
import Foundation
import IdentifiedCollections
import OrderedCollections
import SupacodeSettingsShared
import Testing

@testable import supacode

struct SplitPerTabLayoutTests {
  private static func tab(
    _ title: String,
    customTitle: String? = nil,
    icon: String? = nil,
    ephemeral: Bool = false
  ) -> TabItem {
    let id = UUID()
    return TabItem(
      id: TabID(rawValue: id),
      title: title,
      customTitle: customTitle,
      icon: icon,
      content: ContentSnapshot(
        id: ContentID(rawValue: id),
        state: .terminal(
          TerminalContentState(
            workingDirectory: nil,
            launch: ephemeral ? LaunchOverride(command: "make", bypassZmx: true) : nil
          )
        )
      )
    )
  }

  /// v2 → split-per-tab with pane and group ids minted from `UUID.incrementing`.
  private static func convertToSplitPerTab(_ layout: PaneLayout) -> PaneLayout {
    withDependencies {
      $0.uuid = .incrementing
    } operation: {
      @Dependency(\.uuid) var uuid
      return layout.convertedToSplitPerTab(
        mintPaneID: { PaneID(rawValue: uuid()) },
        mintGroupID: { PaneGroupID(rawValue: uuid()) }
      )
    }
  }

  private static func tabIDs(_ layout: PaneLayout) -> Set<TabID> {
    Set(layout.panes.flatMap { $0.tabs.ids })
  }

  /// Active group 1 is A | B (focus B, zoomed on A); parked group 2 is C over
  /// D (focus D); parked group 3 is E. Strip order 1, 2, 3.
  private struct Fixture {
    let paneA = PaneID()
    let paneB = PaneID()
    let paneC = PaneID()
    let paneD = PaneID()
    let paneE = PaneID()
    let tabA = SplitPerTabLayoutTests.tab("a")
    let tabB = SplitPerTabLayoutTests.tab("b")
    let tabC = SplitPerTabLayoutTests.tab("c")
    let tabD = SplitPerTabLayoutTests.tab("d")
    let tabE = SplitPerTabLayoutTests.tab("e")
    let group1 = PaneGroupID(rawValue: UUID())
    let group2 = PaneGroupID(rawValue: UUID())
    let group3 = PaneGroupID(rawValue: UUID())

    func activeTree() throws -> SplitTree<PaneID> {
      let tree = try SplitTree(view: paneA).inserting(view: paneB, at: paneA, direction: .right)
      return tree.settingZoomed(tree.find(id: paneA.rawValue))
    }

    func group2Tree() throws -> SplitTree<PaneID> {
      try SplitTree(view: paneC).inserting(view: paneD, at: paneC, direction: .down)
    }

    func panes() -> IdentifiedArrayOf<Pane> {
      [
        Pane(id: paneA, tabs: [tabA]),
        Pane(id: paneB, tabs: [tabB]),
        Pane(id: paneC, tabs: [tabC]),
        Pane(id: paneD, tabs: [tabD]),
        Pane(id: paneE, tabs: [tabE]),
      ]
    }

    func layout() throws -> PaneLayout {
      PaneLayout(
        tree: try activeTree(),
        panes: panes(),
        focusedPaneID: paneB,
        activeGroupID: group1,
        parkedGroups: [
          PaneGroup(id: group2, tree: try group2Tree(), focusedPaneID: paneD),
          PaneGroup(id: group3, tree: SplitTree(view: paneE), focusedPaneID: paneE),
        ],
        groupOrder: [group1, group2, group3]
      )
    }
  }

  // MARK: - Conversions.

  @Test func tabsPerSplitToSplitPerTabMintsGroupsInLeafThenStripOrder() throws {
    let paneA = PaneID()
    let paneB = PaneID()
    let tabA1 = Self.tab("a1")
    let tabA2 = Self.tab("a2")
    let tabA3 = Self.tab("a3", customTitle: "pinned", icon: "star")
    let tabB1 = Self.tab("b1")
    let tabB2 = Self.tab("b2", customTitle: "logs")
    var tree = try SplitTree(view: paneA).inserting(view: paneB, at: paneA, direction: .right, ratio: 0.3)
    tree = tree.settingZoomed(tree.find(id: paneB.rawValue))
    let layout = PaneLayout(
      tree: tree,
      panes: [
        Pane(id: paneA, tabs: [tabA1, tabA2, tabA3], selectedTabID: tabA2.id),
        Pane(id: paneB, tabs: [tabB1, tabB2], selectedTabID: tabB1.id),
      ],
      focusedPaneID: paneB
    )

    let converted = Self.convertToSplitPerTab(layout)

    // Active group first, then a pane id and a group id per moved tab (АР3).
    #expect(converted.activeGroupID == PaneGroupID(rawValue: UUID(0)))
    #expect(converted.groupOrder == [0, 2, 4, 6].map { PaneGroupID(rawValue: UUID($0)) })
    #expect(converted.parkedGroups.count == 3)
    // The split, its zoom and focus are untouched.
    #expect(converted.tree == layout.tree)
    #expect(converted.tree.zoomed != nil)
    #expect(converted.focusedPaneID == paneB)
    #expect(Array(try #require(converted.panes[id: paneA]).tabs) == [tabA2])
    #expect(Array(try #require(converted.panes[id: paneB]).tabs) == [tabB1])
    // Every other tab travels as a value (ids, titles, customTitle, icon) into a one-pane group.
    // Each moved tab mints its pane id right before its group id.
    let expected: [(tab: TabItem, group: Int)] = [(tabA1, 2), (tabA3, 4), (tabB2, 6)]
    for entry in expected {
      let paneID = PaneID(rawValue: UUID(entry.group - 1))
      let groupID = PaneGroupID(rawValue: UUID(entry.group))
      let pane = try #require(converted.panes[id: paneID])
      #expect(Array(pane.tabs) == [entry.tab])
      #expect(pane.selectedTabID == entry.tab.id)
      #expect(
        converted.parkedGroups[id: groupID]
          == PaneGroup(id: groupID, tree: SplitTree(view: paneID), focusedPaneID: paneID)
      )
    }
    #expect(converted.isConsistent(for: .splitPerTab))
    #expect(!converted.isConsistent(for: .tabsPerSplit))
  }

  @Test func splitPerTabToTabsPerSplitAppendsInGroupThenLeafOrder() throws {
    let fixture = Fixture()
    var layout = try fixture.layout()
    // Strip order differs from the parked array order: the strip order wins.
    layout.groupOrder = [fixture.group1, fixture.group3, fixture.group2]
    #expect(layout.isConsistent(for: .splitPerTab))

    let result = layout.convertedToTabsPerSplit()

    let home = try #require(result.layout.panes[id: fixture.paneB])
    #expect(Array(home.tabs) == [fixture.tabB, fixture.tabE, fixture.tabC, fixture.tabD])
    #expect(home.selectedTabID == fixture.tabB.id)
    #expect(result.dissolvedPaneIDs == [fixture.paneC, fixture.paneD, fixture.paneE])
    #expect(result.layout.panes.ids == [fixture.paneA, fixture.paneB])
    #expect(result.layout.tree == layout.tree)
    #expect(result.layout.focusedPaneID == fixture.paneB)
    #expect(result.layout.activeGroupID == nil)
    #expect(result.layout.parkedGroups.isEmpty)
    #expect(result.layout.groupOrder.isEmpty)
    #expect(result.layout.isConsistent(for: .tabsPerSplit))
  }

  @Test func bothConversionsKeepEveryContentAndTab() throws {
    let paneA = PaneID()
    let paneB = PaneID()
    let layout = PaneLayout(
      tree: try SplitTree(view: paneA).inserting(view: paneB, at: paneA, direction: .down),
      panes: [
        Pane(id: paneA, tabs: [Self.tab("1"), Self.tab("2"), Self.tab("3")]),
        Pane(id: paneB, tabs: [Self.tab("4"), Self.tab("5")]),
      ],
      focusedPaneID: paneA
    )
    let splitPerTab = Self.convertToSplitPerTab(layout)
    #expect(Set(splitPerTab.allContentIDs) == Set(layout.allContentIDs))
    #expect(Self.tabIDs(splitPerTab) == Self.tabIDs(layout))

    let back = splitPerTab.convertedToTabsPerSplit()
    #expect(back.layout.isConsistent(for: .tabsPerSplit))
    #expect(Set(back.layout.allContentIDs) == Set(layout.allContentIDs))
    #expect(Self.tabIDs(back.layout) == Self.tabIDs(layout))
    #expect(back.dissolvedPaneIDs.count == 3)
  }

  @Test func conversionsLeaveTheWrongShapeUnchanged() throws {
    let empty = PaneLayout()
    #expect(Self.convertToSplitPerTab(empty) == empty)
    let splitPerTab = try Fixture().layout()
    #expect(Self.convertToSplitPerTab(splitPerTab) == splitPerTab)
    let tabsPerSplit = splitPerTab.convertedToTabsPerSplit().layout
    let result = tabsPerSplit.convertedToTabsPerSplit()
    #expect(result.layout == tabsPerSplit)
    #expect(result.dissolvedPaneIDs.isEmpty)
  }

  // MARK: - Invariants.

  @Test func isConsistentRejectsEachBrokenGroupInvariant() throws {
    let fixture = Fixture()
    let valid = try fixture.layout()
    #expect(valid.isConsistent)
    #expect(valid.isConsistent(for: .splitPerTab))

    // 1. A leaf in two trees.
    var sharedLeaf = valid
    sharedLeaf.parkedGroups[id: fixture.group3]?.tree = try SplitTree(view: fixture.paneE)
      .inserting(view: fixture.paneA, at: fixture.paneE, direction: .right)
    #expect(!sharedLeaf.isConsistent)
    // 1. A pane in no tree.
    var orphan = valid
    orphan.parkedGroups.remove(id: fixture.group3)
    orphan.groupOrder = [fixture.group1, fixture.group2]
    #expect(!orphan.isConsistent)
    // 2. An empty parked pane.
    var emptyPane = valid
    emptyPane.panes[id: fixture.paneE]?.tabs = []
    #expect(!emptyPane.isConsistent)
    // 3. Focus on a parked pane.
    var parkedFocus = valid
    parkedFocus.focusedPaneID = fixture.paneC
    #expect(!parkedFocus.isConsistent)
    // 4. Group state without an active group.
    var strayOrder = valid.convertedToTabsPerSplit().layout
    #expect(strayOrder.isConsistent)
    strayOrder.groupOrder = [fixture.group1]
    #expect(!strayOrder.isConsistent)
    // 5. Duplicate strip entry, missing strip entry, active group also parked, empty active.
    var duplicateOrder = valid
    duplicateOrder.groupOrder.append(fixture.group2)
    #expect(!duplicateOrder.isConsistent)
    var missingOrder = valid
    missingOrder.groupOrder = [fixture.group1, fixture.group2]
    #expect(!missingOrder.isConsistent)
    var activeParked = valid
    activeParked.parkedGroups.remove(id: fixture.group3)
    activeParked.parkedGroups.append(
      PaneGroup(id: fixture.group1, tree: SplitTree(view: fixture.paneE), focusedPaneID: fixture.paneE)
    )
    activeParked.groupOrder = [fixture.group1, fixture.group2]
    #expect(!activeParked.isConsistent)
    let emptyActive = PaneLayout(
      tree: SplitTree(),
      panes: [],
      focusedPaneID: nil,
      activeGroupID: fixture.group1,
      parkedGroups: [],
      groupOrder: [fixture.group1]
    )
    #expect(!emptyActive.isConsistent)
    // 6. Parked focus outside its tree; an empty parked tree.
    var strayParkedFocus = valid
    strayParkedFocus.parkedGroups[id: fixture.group2]?.focusedPaneID = fixture.paneE
    #expect(!strayParkedFocus.isConsistent)
    var emptyParkedTree = valid
    emptyParkedTree.parkedGroups[id: fixture.group3]?.tree = SplitTree()
    emptyParkedTree.panes.remove(id: fixture.paneE)
    #expect(!emptyParkedTree.isConsistent)
  }

  @Test func splitPerTabShapeNeedsOneTabPerPaneAndAnActiveGroup() throws {
    let fixture = Fixture()
    let valid = try fixture.layout()
    #expect(valid.isSplitPerTabShape)
    #expect(PaneLayout().isSplitPerTabShape)
    #expect(PaneLayout().isConsistent(for: .splitPerTab))
    #expect(PaneLayout().isConsistent(for: .tabsPerSplit))

    var twoTabs = valid
    twoTabs.panes[id: fixture.paneA]?.tabs.append(Self.tab("extra"))
    #expect(twoTabs.isConsistent)
    #expect(!twoTabs.isSplitPerTabShape)
    #expect(!twoTabs.isConsistent(for: .splitPerTab))

    // A one-tab v2 layout has no active group, so it is not split-per-tab.
    let paneID = PaneID()
    let tabsPerSplit = PaneLayout(tree: SplitTree(view: paneID), panes: [Pane(id: paneID, tabs: [Self.tab("x")])])
    #expect(!tabsPerSplit.isSplitPerTabShape)
    #expect(tabsPerSplit.isConsistent(for: .tabsPerSplit))
    #expect(!tabsPerSplit.isConsistent(for: .splitPerTab))
  }

  // MARK: - Lookups.

  @Test func lookupsResolveGroupsAndStripPositions() throws {
    let fixture = Fixture()
    let layout = try fixture.layout()

    #expect(layout.parkedGroupID(containingPane: fixture.paneC) == fixture.group2)
    #expect(layout.parkedGroupID(containingPane: fixture.paneA) == nil)
    #expect(layout.parkedGroupID(containingPane: PaneID()) == nil)
    #expect(layout.groupID(containingPane: fixture.paneA) == fixture.group1)
    #expect(layout.groupID(containingPane: fixture.paneE) == fixture.group3)
    #expect(layout.groupID(containingPane: PaneID()) == nil)
    #expect(layout.convertedToTabsPerSplit().layout.groupID(containingPane: fixture.paneA) == nil)

    #expect(layout.tree(ofGroup: fixture.group1) == layout.tree)
    #expect(layout.tree(ofGroup: fixture.group2)?.leaves() == [fixture.paneC, fixture.paneD])
    #expect(layout.tree(ofGroup: PaneGroupID(rawValue: UUID())) == nil)
    #expect(layout.focusedPaneID(ofGroup: fixture.group1) == fixture.paneB)
    #expect(layout.focusedPaneID(ofGroup: fixture.group2) == fixture.paneD)
    #expect(layout.focusedPaneID(ofGroup: PaneGroupID(rawValue: UUID())) == nil)

    #expect(layout.groupIndex(of: fixture.group1) == 1)
    #expect(layout.groupIndex(of: fixture.group3) == 3)
    #expect(layout.groupIndex(of: PaneGroupID(rawValue: UUID())) == nil)
    #expect(layout.groupID(atIndex: 0) == fixture.group1)
    #expect(layout.groupID(atIndex: 2) == fixture.group2)
    #expect(layout.groupID(atIndex: 99) == fixture.group3)
    #expect(PaneLayout().groupID(atIndex: 1) == nil)

    #expect(layout.groupID(relativeToActive: true) == fixture.group2)
    #expect(layout.groupID(relativeToActive: false) == fixture.group3)
    var lastActive = layout
    lastActive.activateGroup(fixture.group3)
    #expect(lastActive.groupID(relativeToActive: true) == fixture.group1)
    let single = Self.convertToSplitPerTab(
      PaneLayout(tree: SplitTree(view: fixture.paneA), panes: [Pane(id: fixture.paneA, tabs: [fixture.tabA])])
    )
    #expect(single.groupOrder.count == 1)
    #expect(single.groupID(relativeToActive: true) == nil)
  }

  // MARK: - Mutating helpers.

  @Test func activateGroupSwapsTreesAndFocusAndKeepsZoomPerGroup() throws {
    let fixture = Fixture()
    var original = try fixture.layout()
    let activeTree = try fixture.activeTree()
    let group2Tree = try fixture.group2Tree()
    let zoomedGroup2Tree = group2Tree.settingZoomed(group2Tree.find(id: fixture.paneD.rawValue))
    original.parkedGroups[id: fixture.group2]?.tree = zoomedGroup2Tree
    var layout = original

    layout.activateGroup(fixture.group2)

    #expect(layout.activeGroupID == fixture.group2)
    #expect(layout.tree == zoomedGroup2Tree)
    #expect(layout.focusedPaneID == fixture.paneD)
    #expect(
      layout.parkedGroups[id: fixture.group1]
        == PaneGroup(id: fixture.group1, tree: activeTree, focusedPaneID: fixture.paneB)
    )
    #expect(layout.parkedGroups[id: fixture.group1]?.tree.zoomed != nil)
    #expect(layout.groupOrder == original.groupOrder)
    #expect(layout.panes == original.panes)
    #expect(layout.isConsistent(for: .splitPerTab))

    layout.activateGroup(fixture.group1)
    #expect(layout == original)

    // The active group and an unknown id are no-ops.
    layout.activateGroup(fixture.group1)
    layout.activateGroup(PaneGroupID(rawValue: UUID()))
    #expect(layout == original)
  }

  @Test func modifyTreeWritesBackTheOwningTree() throws {
    let fixture = Fixture()
    var layout = try fixture.layout()
    let activeTree = try fixture.activeTree()

    let parkedLeaves = layout.modifyTree(containing: fixture.paneC) { tree in
      tree = tree.settingZoomed(tree.find(id: fixture.paneC.rawValue))
      return tree.leaves().count
    }
    #expect(parkedLeaves == 2)
    #expect(layout.parkedGroups[id: fixture.group2]?.tree.zoomed == .leaf(view: fixture.paneC))
    #expect(layout.tree == activeTree)

    let activeLeaves = layout.modifyTree(containing: fixture.paneB) { tree in
      tree = tree.settingZoomed(nil)
      return tree.leaves().count
    }
    #expect(activeLeaves == 2)
    #expect(layout.tree.zoomed == nil)

    let before = layout
    let unknown = layout.modifyTree(containing: PaneID()) { tree in
      tree = SplitTree()
      return 0
    }
    #expect(unknown == nil)
    #expect(layout == before)
  }

  @Test func removeLeafFromAParkedGroupRefocusesOrDropsTheGroup() throws {
    let fixture = Fixture()
    var layout = try fixture.layout()
    let activeTree = try fixture.activeTree()

    // The parked group's focused leaf goes: its focus moves to the survivor.
    layout.removeLeaf(fixture.paneD)
    layout.panes.remove(id: fixture.paneD)
    #expect(layout.parkedGroups[id: fixture.group2]?.tree.leaves() == [fixture.paneC])
    #expect(layout.parkedGroups[id: fixture.group2]?.focusedPaneID == fixture.paneC)
    #expect(layout.tree == activeTree)
    #expect(layout.focusedPaneID == fixture.paneB)
    #expect(layout.isConsistent(for: .splitPerTab))

    // The parked group's last leaf goes: the group leaves the strip.
    layout.removeLeaf(fixture.paneE)
    layout.panes.remove(id: fixture.paneE)
    #expect(layout.parkedGroups[id: fixture.group3] == nil)
    #expect(layout.groupOrder == [fixture.group1, fixture.group2])
    #expect(layout.activeGroupID == fixture.group1)
    #expect(layout.isConsistent(for: .splitPerTab))
  }

  @Test func emptyingTheActiveGroupPromotesThePreviousElseTheNextGroup() throws {
    let fixture = Fixture()
    let group2Tree = try fixture.group2Tree()
    // Group 1 is first in the strip: the next group takes over.
    var first = try fixture.layout()
    for pane in [fixture.paneA, fixture.paneB] {
      first.removeLeaf(pane)
      first.panes.remove(id: pane)
    }
    #expect(first.activeGroupID == fixture.group2)
    #expect(first.tree == group2Tree)
    #expect(first.focusedPaneID == fixture.paneD)
    #expect(first.groupOrder == [fixture.group2, fixture.group3])
    #expect(first.parkedGroups.ids == [fixture.group3])
    #expect(first.isConsistent(for: .splitPerTab))

    // Group 1 sits between 2 and 3: the previous group takes over (ДР5).
    var middle = try fixture.layout()
    middle.groupOrder = [fixture.group3, fixture.group1, fixture.group2]
    for pane in [fixture.paneA, fixture.paneB] {
      middle.removeLeaf(pane)
      middle.panes.remove(id: pane)
    }
    #expect(middle.activeGroupID == fixture.group3)
    #expect(middle.focusedPaneID == fixture.paneE)
    #expect(middle.groupOrder == [fixture.group3, fixture.group2])
    #expect(middle.isConsistent(for: .splitPerTab))
  }

  @Test func emptyingTheLastGroupEmptiesTheLayout() throws {
    let fixture = Fixture()
    var layout = PaneLayout(
      tree: try fixture.activeTree(),
      panes: [Pane(id: fixture.paneA, tabs: [fixture.tabA]), Pane(id: fixture.paneB, tabs: [fixture.tabB])],
      focusedPaneID: fixture.paneA,
      activeGroupID: fixture.group1,
      parkedGroups: [],
      groupOrder: [fixture.group1]
    )
    for pane in [fixture.paneA, fixture.paneB] {
      layout.removeLeaf(pane)
      layout.panes.remove(id: pane)
    }
    #expect(layout.tree.isEmpty)
    #expect(layout.activeGroupID == nil)
    #expect(layout.groupOrder.isEmpty)
    #expect(layout.focusedPaneID == nil)
    #expect(layout.isConsistent(for: .splitPerTab))
    #expect(layout.isConsistent(for: .tabsPerSplit))
  }

  // MARK: - Ephemeral stripping.

  @Test func strippingDropsAParkedScriptGroup() throws {
    let fixture = Fixture()
    var layout = try fixture.layout()
    let script = Self.tab("script", ephemeral: true)
    layout.panes[id: fixture.paneE] = Pane(id: fixture.paneE, tabs: [script])

    let stripped = layout.strippingEphemeralContent()

    #expect(stripped.panes[id: fixture.paneE] == nil)
    #expect(stripped.parkedGroups[id: fixture.group3] == nil)
    #expect(stripped.groupOrder == [fixture.group1, fixture.group2])
    #expect(stripped.focusedPaneID == fixture.paneB)
    #expect(stripped.isConsistent(for: .splitPerTab))
  }

  @Test func strippingTheFocusedScriptPaneNeverFocusesAParkedPane() throws {
    let fixture = Fixture()
    var layout = try fixture.layout()
    let script = Self.tab("script", ephemeral: true)
    // Parked panes first, so `panes.first` is a parked pane.
    layout.panes = [
      Pane(id: fixture.paneC, tabs: [fixture.tabC]),
      Pane(id: fixture.paneD, tabs: [fixture.tabD]),
      Pane(id: fixture.paneE, tabs: [fixture.tabE]),
      Pane(id: fixture.paneA, tabs: [fixture.tabA]),
      Pane(id: fixture.paneB, tabs: [script]),
    ]
    #expect(layout.isConsistent(for: .splitPerTab))

    let stripped = layout.strippingEphemeralContent()

    #expect(stripped.focusedPaneID == fixture.paneA)
    #expect(stripped.tree.leaves() == [fixture.paneA])
    #expect(stripped.activeGroupID == fixture.group1)
    #expect(stripped.isConsistent(for: .splitPerTab))
  }

  @Test func strippingTheWholeActiveGroupPromotesTheNeighbour() throws {
    let fixture = Fixture()
    var layout = try fixture.layout()
    layout.groupOrder = [fixture.group2, fixture.group1, fixture.group3]
    layout.panes[id: fixture.paneA] = Pane(id: fixture.paneA, tabs: [Self.tab("s1", ephemeral: true)])
    layout.panes[id: fixture.paneB] = Pane(id: fixture.paneB, tabs: [Self.tab("s2", ephemeral: true)])

    let stripped = layout.strippingEphemeralContent()

    #expect(stripped.activeGroupID == fixture.group2)
    #expect(stripped.focusedPaneID == fixture.paneD)
    #expect(stripped.groupOrder == [fixture.group2, fixture.group3])
    #expect(stripped.panes.ids == [fixture.paneC, fixture.paneD, fixture.paneE])
    #expect(stripped.isConsistent(for: .splitPerTab))
  }

  // MARK: - Fold and unfold.

  @Test func foldOfATabsPerSplitLayoutIsItself() throws {
    let paneID = PaneID()
    let layout = PaneLayout(tree: SplitTree(view: paneID), panes: [Pane(id: paneID, tabs: [Self.tab("x")])])
    let folded = layout.foldedForPersistence()
    #expect(folded.layout == layout)
    #expect(folded.sidecar == nil)
  }

  @Test func foldIsAConsistentTabsPerSplitLayoutHoldingEveryContent() throws {
    let fixture = Fixture()
    let layout = try fixture.layout()

    let folded = layout.foldedForPersistence()

    #expect(folded.layout.isConsistent(for: .tabsPerSplit))
    #expect(Set(folded.layout.allContentIDs) == Set(layout.allContentIDs))
    #expect(
      Array(try #require(folded.layout.panes[id: fixture.paneB]).tabs)
        == [fixture.tabB, fixture.tabC, fixture.tabD, fixture.tabE]
    )
    let expected = SplitPerTabSidecar(
      activeGroupID: fixture.group1,
      groupOrder: [fixture.group1, fixture.group2, fixture.group3],
      parkedGroups: [
        SplitPerTabSidecar.ParkedGroup(
          id: fixture.group2,
          tree: try fixture.group2Tree(),
          focusedPaneID: fixture.paneD,
          panes: [
            SplitPerTabSidecar.PaneTab(paneID: fixture.paneC, tabID: fixture.tabC.id),
            SplitPerTabSidecar.PaneTab(paneID: fixture.paneD, tabID: fixture.tabD.id),
          ]
        ),
        SplitPerTabSidecar.ParkedGroup(
          id: fixture.group3,
          tree: SplitTree(view: fixture.paneE),
          focusedPaneID: fixture.paneE,
          panes: [SplitPerTabSidecar.PaneTab(paneID: fixture.paneE, tabID: fixture.tabE.id)]
        ),
      ]
    )
    #expect(folded.sidecar == expected)
  }

  @Test func unfoldOfAFoldRestoresTheGroupsInCanonicalPaneOrder() throws {
    let fixture = Fixture()
    var live = try fixture.layout()
    // A live pane order that is not canonical.
    live.panes = [
      Pane(id: fixture.paneE, tabs: [fixture.tabE]),
      Pane(id: fixture.paneB, tabs: [fixture.tabB]),
      Pane(id: fixture.paneD, tabs: [fixture.tabD]),
      Pane(id: fixture.paneA, tabs: [fixture.tabA]),
      Pane(id: fixture.paneC, tabs: [fixture.tabC]),
    ]
    live.activateGroup(fixture.group3)
    live.activateGroup(fixture.group1)
    let folded = live.foldedForPersistence()
    let sidecar = try #require(folded.sidecar)

    let unfolded = try #require(folded.layout.unfolding(sidecar))

    #expect(unfolded.isConsistent(for: .splitPerTab))
    #expect(unfolded.tree == live.tree)
    #expect(unfolded.tree.zoomed != nil)
    #expect(unfolded.focusedPaneID == live.focusedPaneID)
    #expect(unfolded.activeGroupID == live.activeGroupID)
    #expect(unfolded.groupOrder == live.groupOrder)
    #expect(Set(unfolded.parkedGroups.ids) == Set(live.parkedGroups.ids))
    for group in live.parkedGroups {
      #expect(unfolded.parkedGroups[id: group.id] == group)
    }
    #expect(
      Dictionary(uniqueKeysWithValues: unfolded.panes.map { ($0.id, $0) })
        == Dictionary(uniqueKeysWithValues: live.panes.map { ($0.id, $0) })
    )
    // Canonical order: base panes as stored, then parked panes by strip, then leaf order.
    #expect(unfolded.panes.ids == [fixture.paneB, fixture.paneA, fixture.paneC, fixture.paneD, fixture.paneE])
    // The fold of an unfolded record is the same record.
    let refolded = unfolded.foldedForPersistence()
    #expect(refolded.layout == folded.layout)
    #expect(refolded.sidecar == folded.sidecar)
  }

  @Test func unfoldFallsBackWhenAnyCheckFails() throws {
    let fixture = Fixture()
    let live = try fixture.layout()
    let folded = live.foldedForPersistence()
    let base = folded.layout
    let sidecar = try #require(folded.sidecar)
    #expect(base.unfolding(sidecar) != nil)

    // 1. The base is split-per-tab, or inconsistent.
    #expect(live.unfolding(sidecar) == nil)
    var inconsistentBase = base
    inconsistentBase.focusedPaneID = nil
    #expect(inconsistentBase.unfolding(sidecar) == nil)

    // 2. A duplicated parked id, a duplicate strip entry, a strip without the
    // active group, the active id also parked.
    var duplicateParked = sidecar
    duplicateParked.parkedGroups[1] = SplitPerTabSidecar.ParkedGroup(
      id: fixture.group2,
      tree: SplitTree(view: fixture.paneE),
      focusedPaneID: fixture.paneE,
      panes: [SplitPerTabSidecar.PaneTab(paneID: fixture.paneE, tabID: fixture.tabE.id)]
    )
    #expect(base.unfolding(duplicateParked) == nil)
    var duplicateOrder = sidecar
    duplicateOrder.groupOrder.append(fixture.group3)
    #expect(base.unfolding(duplicateOrder) == nil)
    var missingActive = sidecar
    missingActive.groupOrder = [fixture.group2, fixture.group3]
    #expect(base.unfolding(missingActive) == nil)
    var activeParked = sidecar
    activeParked.parkedGroups[1] = SplitPerTabSidecar.ParkedGroup(
      id: fixture.group1,
      tree: SplitTree(view: fixture.paneE),
      focusedPaneID: fixture.paneE,
      panes: [SplitPerTabSidecar.PaneTab(paneID: fixture.paneE, tabID: fixture.tabE.id)]
    )
    activeParked.groupOrder = [fixture.group1, fixture.group2]
    #expect(base.unfolding(activeParked) == nil)

    // 3. An unknown tab, the focused pane's selected tab, a tab listed twice.
    var unknownTab = sidecar
    unknownTab.parkedGroups[1].panes = [SplitPerTabSidecar.PaneTab(paneID: fixture.paneE, tabID: TabID())]
    #expect(base.unfolding(unknownTab) == nil)
    var focusedSelection = sidecar
    focusedSelection.parkedGroups[1].panes = [
      SplitPerTabSidecar.PaneTab(paneID: fixture.paneE, tabID: fixture.tabB.id)
    ]
    #expect(base.unfolding(focusedSelection) == nil)
    var tabTwice = sidecar
    tabTwice.parkedGroups[1].panes = [SplitPerTabSidecar.PaneTab(paneID: fixture.paneE, tabID: fixture.tabC.id)]
    #expect(base.unfolding(tabTwice) == nil)

    // 4. A pane id the base already has, a pane id listed twice.
    var basePane = sidecar
    basePane.parkedGroups[1].tree = SplitTree(view: fixture.paneA)
    basePane.parkedGroups[1].focusedPaneID = fixture.paneA
    basePane.parkedGroups[1].panes = [SplitPerTabSidecar.PaneTab(paneID: fixture.paneA, tabID: fixture.tabE.id)]
    #expect(base.unfolding(basePane) == nil)
    var paneTwice = sidecar
    paneTwice.parkedGroups[1].tree = SplitTree(view: fixture.paneC)
    paneTwice.parkedGroups[1].focusedPaneID = fixture.paneC
    paneTwice.parkedGroups[1].panes = [SplitPerTabSidecar.PaneTab(paneID: fixture.paneC, tabID: fixture.tabE.id)]
    #expect(base.unfolding(paneTwice) == nil)

    // 5. Tree leaves that are not the group's panes, a focus outside the tree.
    var strayLeaf = sidecar
    strayLeaf.parkedGroups[1].tree = SplitTree(view: PaneID())
    #expect(base.unfolding(strayLeaf) == nil)
    var strayFocus = sidecar
    strayFocus.parkedGroups[0].focusedPaneID = fixture.paneE
    #expect(base.unfolding(strayFocus) == nil)

    // 6. An old build added a tab to an active pane, or a move empties a base pane.
    var extraTab = base
    extraTab.panes[id: fixture.paneA]?.tabs.append(Self.tab("extra"))
    #expect(extraTab.isConsistent)
    #expect(extraTab.unfolding(sidecar) == nil)
    var emptiesBase = sidecar
    emptiesBase.parkedGroups[1].panes = [SplitPerTabSidecar.PaneTab(paneID: fixture.paneE, tabID: fixture.tabA.id)]
    #expect(base.unfolding(emptiesBase) == nil)
  }

  @Test func sidecarWireFormatIsPinned() throws {
    let group1 = PaneGroupID(rawValue: UUID(uuidString: "11111111-0000-0000-0000-000000000001")!)
    let group2 = PaneGroupID(rawValue: UUID(uuidString: "11111111-0000-0000-0000-000000000002")!)
    let pane2 = PaneID(rawValue: UUID(uuidString: "22222222-0000-0000-0000-000000000002")!)
    let tab2 = TabID(rawValue: UUID(uuidString: "33333333-0000-0000-0000-000000000002")!)
    let sidecar = SplitPerTabSidecar(
      activeGroupID: group1,
      groupOrder: [group1, group2],
      parkedGroups: [
        SplitPerTabSidecar.ParkedGroup(
          id: group2,
          tree: SplitTree(view: pane2),
          focusedPaneID: pane2,
          panes: [SplitPerTabSidecar.PaneTab(paneID: pane2, tabID: tab2)]
        )
      ]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = try #require(String(bytes: encoder.encode(sidecar), encoding: .utf8))
    let expected = """
      {"activeGroupID":"11111111-0000-0000-0000-000000000001",\
      "groupOrder":["11111111-0000-0000-0000-000000000001","11111111-0000-0000-0000-000000000002"],\
      "parkedGroups":[{"focusedPaneID":"22222222-0000-0000-0000-000000000002",\
      "id":"11111111-0000-0000-0000-000000000002",\
      "panes":[{"paneID":"22222222-0000-0000-0000-000000000002",\
      "tabID":"33333333-0000-0000-0000-000000000002"}],\
      "tree":{"root":{"kind":"leaf","leaf":"22222222-0000-0000-0000-000000000002"}}}]}
      """
    #expect(json == expected)
    #expect(try JSONDecoder().decode(SplitPerTabSidecar.self, from: Data(json.utf8)) == sidecar)
  }
}
