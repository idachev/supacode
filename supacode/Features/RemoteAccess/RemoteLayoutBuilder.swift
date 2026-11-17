import Foundation
import IdentifiedCollections
import SupacodeSettingsShared

/// `list.worktrees[].layout`: how a worktree's terminal tabs sit in panes and
/// splits, as the Mac shows them. See `docs/remote-access-protocol.md`.
nonisolated struct RemoteLayout: Encodable, Equatable, Sendable {
  /// `TerminalLayoutMode.rawValue`.
  let mode: String
  /// `RemoteLayoutBuilder.mainGroupID` in `tabsPerSplit`.
  let activeGroupId: String
  let groups: [RemoteLayoutGroup]
  let panes: [RemoteLayoutPane]
}

nonisolated struct RemoteLayoutGroup: Encodable, Equatable, Sendable {
  let id: String
  /// Omitted when nil.
  var focusedPaneId: String?
  /// Omitted when nil.
  var zoomedPaneId: String?
  let tree: RemoteLayoutNode
}

/// A split-tree node: `{"pane":"<id>"}` or
/// `{"split":{"direction":…,"ratio":…,"left":…,"right":…}}`.
nonisolated indirect enum RemoteLayoutNode: Encodable, Equatable, Sendable {
  case pane(String)
  case split(direction: String, ratio: Double, left: RemoteLayoutNode, right: RemoteLayoutNode)

  private enum CodingKeys: String, CodingKey {
    case pane, split
  }

  private enum SplitKeys: String, CodingKey {
    case direction, ratio, left, right
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .pane(let id):
      try container.encode(id, forKey: .pane)
    case .split(let direction, let ratio, let left, let right):
      var split = container.nestedContainer(keyedBy: SplitKeys.self, forKey: .split)
      try split.encode(direction, forKey: .direction)
      try split.encode(ratio, forKey: .ratio)
      try split.encode(left, forKey: .left)
      try split.encode(right, forKey: .right)
    }
  }
}

nonisolated struct RemoteLayoutPane: Encodable, Equatable, Sendable {
  let id: String
  /// Terminal tabs only, in strip order.
  let tabIds: [String]
  /// Omitted when nil.
  var selectedTabId: String?
}

nonisolated enum RemoteLayoutBuilder {
  static let mainGroupID = "main"

  /// The layout a client sees, or nil when the layout has no terminal tab (or
  /// no group with a tree). Panes come from the flat `layout.panes`; in
  /// `splitPerTab` the active group's tree is `layout.tree` and the others are
  /// `layout.parkedGroups`, listed in strip order (`groupOrder`).
  static func build(_ layout: PaneLayout, mode: TerminalLayoutMode) -> RemoteLayout? {
    let hasTerminalTab = layout.panes.contains { pane in
      pane.tabs.contains { $0.content.kind == .terminal }
    }
    guard hasTerminalTab else { return nil }
    let groups = groups(of: layout, mode: mode)
    guard let firstGroup = groups.first else { return nil }
    let activeGroupID =
      mode == .splitPerTab
      ? layout.activeGroupID.map { $0.rawValue.uuidString } ?? firstGroup.id
      : mainGroupID
    return RemoteLayout(
      mode: mode.rawValue,
      activeGroupId: activeGroupID,
      groups: groups,
      panes: layout.panes.map(pane)
    )
  }

  private static func groups(of layout: PaneLayout, mode: TerminalLayoutMode) -> [RemoteLayoutGroup] {
    switch mode {
    case .tabsPerSplit:
      return group(id: mainGroupID, tree: layout.tree, focusedPaneID: layout.focusedPaneID).map { [$0] } ?? []
    case .splitPerTab:
      return layout.groupOrder.compactMap { groupID in
        if groupID == layout.activeGroupID {
          return group(id: groupID.rawValue.uuidString, tree: layout.tree, focusedPaneID: layout.focusedPaneID)
        }
        guard let parked = layout.parkedGroups[id: groupID] else { return nil }
        return group(id: groupID.rawValue.uuidString, tree: parked.tree, focusedPaneID: parked.focusedPaneID)
      }
    }
  }

  private static func group(id: String, tree: SplitTree<PaneID>, focusedPaneID: PaneID?) -> RemoteLayoutGroup? {
    guard let root = tree.root else { return nil }
    var zoomedPaneID: String?
    if case .leaf(let pane) = tree.zoomed {
      zoomedPaneID = pane.rawValue.uuidString
    }
    return RemoteLayoutGroup(
      id: id,
      focusedPaneId: focusedPaneID.map { $0.rawValue.uuidString },
      zoomedPaneId: zoomedPaneID,
      tree: node(root)
    )
  }

  private static func node(_ node: SplitTree<PaneID>.Node) -> RemoteLayoutNode {
    switch node {
    case .leaf(let pane):
      return .pane(pane.rawValue.uuidString)
    case .split(let split):
      return .split(
        direction: split.direction.rawValue,
        ratio: split.ratio,
        left: Self.node(split.left),
        right: Self.node(split.right)
      )
    }
  }

  /// The same terminal-tab filter as `RemoteSnapshotSource.tabs(in:runtime:)`.
  private static func pane(_ pane: Pane) -> RemoteLayoutPane {
    let terminalTabs = pane.tabs.filter { $0.content.kind == .terminal }
    return RemoteLayoutPane(
      id: pane.id.rawValue.uuidString,
      tabIds: terminalTabs.map { $0.id.rawValue.uuidString },
      selectedTabId: pane.selectedTabID.flatMap { terminalTabs[id: $0] }.map { $0.id.rawValue.uuidString }
    )
  }
}
