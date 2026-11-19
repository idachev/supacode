import Foundation

/// What the laptop chose in one worktree's layout; kept across pushed lists.
nonisolated struct RemoteLocalSelection: Equatable, Sendable {
  var activeGroupID: String?
  /// group id → pane id
  var focusedPaneID: [String: String] = [:]
  /// group id → pane id
  var zoomedPaneID: [String: String] = [:]
  /// pane id → tab id
  var selectedTabID: [String: String] = [:]
}

/// One worktree's layout as the window draws it.
nonisolated struct RemoteLayoutProjection: Equatable, Sendable {
  nonisolated struct PaneView: Equatable, Identifiable, Sendable {
    let id: String
    let tabs: [RemoteClientTab]
    let selectedTabID: String?
  }

  nonisolated struct GroupView: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let tree: RemoteClientLayoutNode
    let focusedPaneID: String?
    let zoomedPaneID: String?
  }

  let mode: String
  /// Strip order; one group in `tabsPerSplit`.
  let groups: [GroupView]
  let activeGroupID: String?
  let panes: [String: PaneView]

  /// The tabs the window shows now: the selected tab of every pane of the active group (only the
  /// zoomed pane's when that group is zoomed), by content id, in tree order.
  var visibleContentIDs: [String] {
    guard let group = groups.first(where: { $0.id == activeGroupID }) else { return [] }
    let paneIDs = group.zoomedPaneID.map { [$0] } ?? Self.paneIDs(in: group.tree)
    var seen = Set<String>()
    return paneIDs.compactMap { paneID -> String? in
      guard let pane = panes[paneID],
        let tab = pane.tabs.first(where: { $0.id == pane.selectedTabID }),
        !tab.contentId.isEmpty,
        seen.insert(tab.contentId).inserted
      else { return nil }
      return tab.contentId
    }
  }

  /// Seeds missing choices from the host's layout, drops choices whose tab, pane or group is
  /// gone, and returns the projection with the kept choices. A worktree without `layout`
  /// projects one group with one pane that holds every tab.
  static func project(
    _ worktree: RemoteClientWorktree,
    selection: inout RemoteLocalSelection
  ) -> RemoteLayoutProjection {
    let layout = worktree.layout ?? Self.singlePane(of: worktree)
    let tabsByID = Dictionary(worktree.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    // Panes that still hold at least one tab the worktree knows.
    var livePanes: [String: (tabs: [RemoteClientTab], hostSelected: String?)] = [:]
    for pane in layout.panes where livePanes[pane.id] == nil {
      var seen = Set<String>()
      let tabs = pane.tabIds.compactMap { id in seen.insert(id).inserted ? tabsByID[id] : nil }
      if !tabs.isEmpty { livePanes[pane.id] = (tabs, pane.selectedTabId) }
    }

    // Groups with their tree pruned to live panes; a group with nothing left is dropped.
    struct RawGroup {
      let id: String
      let tree: RemoteClientLayoutNode
      let paneOrder: [String]
      let focused: String?
      let zoomed: String?
    }
    var rawGroups: [RawGroup] = []
    var seenGroups = Set<String>()
    for group in layout.groups where seenGroups.insert(group.id).inserted {
      guard let tree = Self.prune(group.tree, keeping: Set(livePanes.keys)) else { continue }
      let order = Self.paneIDs(in: tree)
      rawGroups.append(
        RawGroup(
          id: group.id, tree: tree, paneOrder: order,
          focused: Self.firstChoice([selection.focusedPaneID[group.id], group.focusedPaneId], in: order)
            ?? order.first,
          zoomed: Self.firstChoice([selection.zoomedPaneID[group.id], group.zoomedPaneId], in: order)))
    }

    let reachable = Set(rawGroups.flatMap(\.paneOrder))
    var panes: [String: PaneView] = [:]
    var keptSelectedTabs: [String: String] = [:]
    for paneID in reachable {
      guard let live = livePanes[paneID] else { continue }
      let ids = live.tabs.map(\.id)
      let selected = Self.firstChoice([selection.selectedTabID[paneID], live.hostSelected], in: ids) ?? ids[0]
      keptSelectedTabs[paneID] = selected
      panes[paneID] = PaneView(id: paneID, tabs: live.tabs, selectedTabID: selected)
    }

    let groups = rawGroups.map { group in
      let titledPane = group.focused.flatMap { panes[$0] } ?? group.paneOrder.first.flatMap { panes[$0] }
      return GroupView(
        id: group.id,
        title: titledPane?.tabs.first(where: { $0.id == titledPane?.selectedTabID })?.title ?? "",
        tree: group.tree, focusedPaneID: group.focused, zoomedPaneID: group.zoomed)
    }

    let groupIDs = groups.map(\.id)
    let activeGroupID =
      Self.firstChoice([selection.activeGroupID, layout.activeGroupId], in: groupIDs) ?? groupIDs.first

    // Keep exactly what the projection used (and seeded), so a gone tab, pane or group leaves.
    selection = RemoteLocalSelection(
      activeGroupID: activeGroupID,
      focusedPaneID: rawGroups.reduce(into: [:]) { $0[$1.id] = $1.focused },
      zoomedPaneID: rawGroups.reduce(into: [:]) { $0[$1.id] = $1.zoomed },
      selectedTabID: keptSelectedTabs)

    return RemoteLayoutProjection(
      mode: layout.mode, groups: groups, activeGroupID: activeGroupID, panes: panes)
  }

  /// Pane ids of a tree, left before right.
  static func paneIDs(in node: RemoteClientLayoutNode) -> [String] {
    switch node {
    case .pane(let id): [id]
    case .split(_, _, let left, let right): paneIDs(in: left) + paneIDs(in: right)
    }
  }

  /// The tree without the panes not in `live`; a split with one side gone becomes the other side.
  private static func prune(_ node: RemoteClientLayoutNode, keeping live: Set<String>) -> RemoteClientLayoutNode? {
    switch node {
    case .pane(let id):
      return live.contains(id) ? node : nil
    case .split(let direction, let ratio, let left, let right):
      switch (prune(left, keeping: live), prune(right, keeping: live)) {
      case (let left?, let right?): return .split(direction: direction, ratio: ratio, left: left, right: right)
      case (let only?, nil), (nil, let only?): return only
      case (nil, nil): return nil
      }
    }
  }

  /// The first candidate that is in `valid`.
  private static func firstChoice(_ candidates: [String?], in valid: [String]) -> String? {
    candidates.lazy.compactMap { $0 }.first { valid.contains($0) }
  }

  /// A worktree the host sent without `layout`: one group, one pane with every tab, the focused
  /// tab (else the first) selected.
  private static func singlePane(of worktree: RemoteClientWorktree) -> RemoteClientLayout {
    let selected = worktree.tabs.first(where: \.focused) ?? worktree.tabs.first
    return RemoteClientLayout(
      mode: "tabsPerSplit", activeGroupId: "main",
      groups: [RemoteClientLayoutGroup(id: "main", focusedPaneId: "main", zoomedPaneId: nil, tree: .pane("main"))],
      panes: [RemoteClientLayoutPane(id: "main", tabIds: worktree.tabs.map(\.id), selectedTabId: selected?.id)])
  }
}
