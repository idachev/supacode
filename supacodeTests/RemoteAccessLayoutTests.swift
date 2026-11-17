import Dependencies
import Foundation
import IdentifiedCollections
import OrderedCollections
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
@Suite struct RemoteAccessLayoutTests {
  private static func tab() -> TabItem {
    let id = UUID()
    return TabItem(
      id: TabID(rawValue: id),
      title: "t",
      content: ContentSnapshot(
        id: ContentID(rawValue: id),
        state: .terminal(TerminalContentState(workingDirectory: nil, launch: nil))
      )
    )
  }

  /// Two single-tab panes side by side (`left` | `right`), `right` focused.
  private struct SideBySide {
    var left = Pane(id: PaneID(), tabs: [RemoteAccessLayoutTests.tab()])
    var right = Pane(id: PaneID(), tabs: [RemoteAccessLayoutTests.tab()])

    func tree() throws -> SplitTree<PaneID> {
      try SplitTree(view: left.id).inserting(view: right.id, at: left.id, direction: .right)
    }

    func layout(zoomedOnLeft: Bool = false) throws -> PaneLayout {
      var tree = try tree()
      if zoomedOnLeft { tree = tree.settingZoomed(tree.find(id: left.id.rawValue)) }
      return PaneLayout(tree: tree, panes: [left, right], focusedPaneID: right.id)
    }
  }

  @Test func aLayoutWithNoTabsHasNoLayout() {
    #expect(RemoteLayoutBuilder.build(PaneLayout(), mode: .tabsPerSplit) == nil)
    let emptyPane = Pane(id: PaneID())
    let layout = PaneLayout(tree: SplitTree(view: emptyPane.id), panes: [emptyPane], focusedPaneID: emptyPane.id)
    #expect(RemoteLayoutBuilder.build(layout, mode: .tabsPerSplit) == nil)
  }

  @Test func tabsPerSplitHasOneMainGroupWithItsTree() throws {
    let fixture = SideBySide()
    let left = fixture.left
    let right = fixture.right
    let remote = try #require(RemoteLayoutBuilder.build(try fixture.layout(), mode: .tabsPerSplit))
    #expect(remote.mode == "tabsPerSplit")
    #expect(remote.activeGroupId == "main")
    #expect(remote.groups.map(\.id) == ["main"])
    #expect(remote.groups[0].focusedPaneId == right.id.rawValue.uuidString)
    #expect(remote.groups[0].zoomedPaneId == nil)
    #expect(
      remote.groups[0].tree
        == .split(
          direction: "horizontal", ratio: 0.5,
          left: .pane(left.id.rawValue.uuidString), right: .pane(right.id.rawValue.uuidString)))
    #expect(remote.panes.map(\.id) == [left, right].map { $0.id.rawValue.uuidString })
    #expect(remote.panes[0].tabIds == left.tabs.map { $0.id.rawValue.uuidString })
    #expect(remote.panes[0].selectedTabId == left.selectedTabID?.rawValue.uuidString)
  }

  @Test func theSelectedTabIsNamedWhenThePaneHasOne() throws {
    var fixture = SideBySide()
    fixture = SideBySide(
      left: Pane(id: fixture.left.id, tabs: fixture.left.tabs, selectedTabID: fixture.left.tabs.first?.id),
      right: fixture.right)
    let remote = try #require(RemoteLayoutBuilder.build(try fixture.layout(), mode: .tabsPerSplit))
    #expect(remote.panes[0].selectedTabId == fixture.left.tabs.first?.id.rawValue.uuidString)
    #expect(remote.panes[0].selectedTabId != nil)
  }

  @Test func aZoomedTreeNamesItsPane() throws {
    let fixture = SideBySide()
    let remote = try #require(
      RemoteLayoutBuilder.build(try fixture.layout(zoomedOnLeft: true), mode: .tabsPerSplit))
    #expect(remote.groups[0].zoomedPaneId == fixture.left.id.rawValue.uuidString)
  }

  @Test func aZoomOnASplitNodeNamesNoPane() throws {
    let fixture = SideBySide()
    let tree = try fixture.tree()
    let layout = PaneLayout(
      tree: tree.settingZoomed(tree.root), panes: [fixture.left, fixture.right], focusedPaneID: fixture.right.id)
    let remote = try #require(RemoteLayoutBuilder.build(layout, mode: .tabsPerSplit))
    #expect(remote.groups[0].zoomedPaneId == nil)
  }

  @Test func theRatioAndDirectionAreKept() throws {
    let fixture = SideBySide()
    let tree = try SplitTree(view: fixture.left.id)
      .inserting(view: fixture.right.id, at: fixture.left.id, direction: .down, ratio: 0.25)
    let layout = PaneLayout(tree: tree, panes: [fixture.left, fixture.right], focusedPaneID: nil)
    let remote = try #require(RemoteLayoutBuilder.build(layout, mode: .tabsPerSplit))
    guard case .split(let direction, let ratio, _, _) = remote.groups[0].tree else {
      Issue.record("expected a split")
      return
    }
    #expect(direction == "vertical")
    #expect(ratio == 0.25)
  }

  /// Active group G1 is one pane; parked group G2 is two panes (zoomed on its second); parked G3 is one pane.
  private struct Grouped {
    let first = Pane(id: PaneID(), tabs: [RemoteAccessLayoutTests.tab()])
    let parkedFirst = Pane(id: PaneID(), tabs: [RemoteAccessLayoutTests.tab()])
    let parkedSecond = Pane(id: PaneID(), tabs: [RemoteAccessLayoutTests.tab()])
    let third = Pane(id: PaneID(), tabs: [RemoteAccessLayoutTests.tab()])
    let groupOne = PaneGroupID(rawValue: UUID())
    let groupTwo = PaneGroupID(rawValue: UUID())
    let groupThree = PaneGroupID(rawValue: UUID())

    func layout(order: [PaneGroupID]) throws -> PaneLayout {
      var parkedTree = try SplitTree(view: parkedFirst.id)
        .inserting(view: parkedSecond.id, at: parkedFirst.id, direction: .down)
      parkedTree = parkedTree.settingZoomed(parkedTree.find(id: parkedSecond.id.rawValue))
      return PaneLayout(
        tree: SplitTree(view: first.id),
        panes: [first, parkedFirst, parkedSecond, third],
        focusedPaneID: first.id,
        activeGroupID: groupOne,
        parkedGroups: [
          PaneGroup(id: groupTwo, tree: parkedTree, focusedPaneID: parkedFirst.id),
          PaneGroup(id: groupThree, tree: SplitTree(view: third.id), focusedPaneID: third.id),
        ],
        groupOrder: order
      )
    }
  }

  @Test func splitPerTabListsEveryGroupInStripOrderAndEveryPane() throws {
    let fixture = Grouped()
    let remote = try #require(
      RemoteLayoutBuilder.build(
        try fixture.layout(order: [fixture.groupOne, fixture.groupTwo, fixture.groupThree]), mode: .splitPerTab))
    #expect(remote.mode == "splitPerTab")
    #expect(remote.activeGroupId == fixture.groupOne.rawValue.uuidString)
    #expect(
      remote.groups.map(\.id)
        == [fixture.groupOne, fixture.groupTwo, fixture.groupThree].map { $0.rawValue.uuidString })
    #expect(remote.groups[0].focusedPaneId == fixture.first.id.rawValue.uuidString)
    #expect(remote.groups[0].tree == .pane(fixture.first.id.rawValue.uuidString))
    #expect(remote.groups[1].focusedPaneId == fixture.parkedFirst.id.rawValue.uuidString)
    #expect(remote.groups[1].zoomedPaneId == fixture.parkedSecond.id.rawValue.uuidString)
    #expect(remote.groups[2].zoomedPaneId == nil)
    #expect(remote.panes.count == 4)
  }

  @Test func theStripOrderWinsOverTheActiveGroupBeingFirst() throws {
    let fixture = Grouped()
    let remote = try #require(
      RemoteLayoutBuilder.build(
        try fixture.layout(order: [fixture.groupTwo, fixture.groupOne, fixture.groupThree]), mode: .splitPerTab))
    #expect(remote.activeGroupId == fixture.groupOne.rawValue.uuidString)
    #expect(
      remote.groups.map(\.id)
        == [fixture.groupTwo, fixture.groupOne, fixture.groupThree].map { $0.rawValue.uuidString })
  }

  @Test func aConvertedLayoutHasOneGroupPerTab() throws {
    let paneID = PaneID()
    let tabs = [Self.tab(), Self.tab(), Self.tab()]
    let layout = PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [Pane(id: paneID, tabs: IdentifiedArray(uniqueElements: tabs), selectedTabID: tabs[0].id)],
      focusedPaneID: paneID
    )
    let converted = withDependencies {
      $0.uuid = .incrementing
    } operation: {
      @Dependency(\.uuid) var uuid
      return layout.convertedToSplitPerTab(
        mintPaneID: { PaneID(rawValue: uuid()) },
        mintGroupID: { PaneGroupID(rawValue: uuid()) }
      )
    }
    let remote = try #require(RemoteLayoutBuilder.build(converted, mode: .splitPerTab))
    #expect(remote.groups.map(\.id) == converted.groupOrder.map { $0.rawValue.uuidString })
    #expect(remote.groups.count == 3)
    #expect(remote.panes.count == 3)
    #expect(remote.panes.flatMap(\.tabIds).sorted() == tabs.map { $0.id.rawValue.uuidString }.sorted())
  }

  @Test func theNodeEncodesAsTheProtocolSays() throws {
    let node = RemoteLayoutNode.split(direction: "vertical", ratio: 0.25, left: .pane("A"), right: .pane("B"))
    let json = try #require(try JSONSerialization.jsonObject(with: RemoteJSON.encode(node)) as? [String: Any])
    let split = try #require(json["split"] as? [String: Any])
    #expect(split["direction"] as? String == "vertical")
    #expect(split["ratio"] as? Double == 0.25)
    #expect((split["left"] as? [String: Any])?["pane"] as? String == "A")
    #expect((split["right"] as? [String: Any])?["pane"] as? String == "B")
  }

  @Test func optionalFieldsAreOmittedWhenNil() throws {
    let group = RemoteLayoutGroup(id: "main", tree: .pane("A"))
    let pane = RemoteLayoutPane(id: "A", tabIds: ["T"])
    let groupJSON = try #require(try JSONSerialization.jsonObject(with: RemoteJSON.encode(group)) as? [String: Any])
    let paneJSON = try #require(try JSONSerialization.jsonObject(with: RemoteJSON.encode(pane)) as? [String: Any])
    #expect(groupJSON["focusedPaneId"] == nil)
    #expect(groupJSON["zoomedPaneId"] == nil)
    #expect(paneJSON["selectedTabId"] == nil)
    #expect((groupJSON["tree"] as? [String: Any])?["pane"] as? String == "A")
  }

  @Test func aWorktreeWithoutLayoutOmitsTheKey() throws {
    let worktree = RemoteWorktree(
      id: "w", name: "n", branch: "b", status: "main", focused: false, title: nil, working: false, tabs: [])
    let json = try #require(try JSONSerialization.jsonObject(with: RemoteJSON.encode(worktree)) as? [String: Any])
    #expect(json["layout"] == nil)
  }
}
