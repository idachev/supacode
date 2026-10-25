import Foundation
import IdentifiedCollections
import SupacodeSettingsShared

/// Identity of a pane, a split-tree leaf holding a strip of tabs.
nonisolated struct PaneID: Hashable, Identifiable, Codable, Sendable {
  let rawValue: UUID

  init() {
    rawValue = UUID()
  }

  init(rawValue: UUID) {
    self.rawValue = rawValue
  }

  var id: UUID { rawValue }

  init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(UUID.self)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// What kind of content a tab hosts; additive for future kinds.
nonisolated enum ContentKind: String, Codable, Sendable {
  case terminal
}

/// How a command-running terminal launches (scripts, prompts). Blocking
/// runners bypass zmx and die with the app; persistence strips this so a
/// stored layout can never replay a command.
nonisolated struct LaunchOverride: Equatable, Codable, Sendable {
  var command: String?
  var initialInput: String?
  var bypassZmx: Bool

  init(command: String? = nil, initialInput: String? = nil, bypassZmx: Bool = false) {
    self.command = command
    self.initialInput = initialInput
    self.bypassZmx = bypassZmx
  }
}

/// Terminal-specific persisted state; the generic layout never sees grids.
nonisolated struct TerminalContentState: Equatable, Codable, Sendable {
  let workingDirectory: String?
  let agents: [TerminalLayoutSnapshot.SurfaceAgentRecord]?
  let frozenGrid: FrozenGrid?
  /// Live-only launch override; the persistence path always strips it.
  let launch: LaunchOverride?

  private enum CodingKeys: String, CodingKey {
    case workingDirectory
    case agents
    case frozenGrid
  }

  init(
    workingDirectory: String?,
    agents: [TerminalLayoutSnapshot.SurfaceAgentRecord]? = nil,
    frozenGrid: FrozenGrid? = nil,
    launch: LaunchOverride? = nil
  ) {
    self.workingDirectory = workingDirectory
    self.agents = agents
    self.frozenGrid = frozenGrid
    self.launch = launch
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
    // `try?` so a future shape change drops the field, not the whole entry.
    agents =
      (try? container.decodeIfPresent(
        [TerminalLayoutSnapshot.SurfaceAgentRecord].self, forKey: .agents
      )) ?? nil
    frozenGrid = (try? container.decodeIfPresent(FrozenGrid.self, forKey: .frozenGrid)) ?? nil
    launch = nil
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
    try container.encodeIfPresent(agents, forKey: .agents)
    try container.encodeIfPresent(frozenGrid, forKey: .frozenGrid)
  }
}

/// Kind-keyed content payload; each case owns its kind's persisted state.
nonisolated enum ContentState: Equatable, Codable, Sendable {
  case terminal(TerminalContentState)

  private enum CodingKeys: String, CodingKey {
    case kind
    case terminal
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(ContentKind.self, forKey: .kind) {
    case .terminal:
      self = .terminal(try container.decode(TerminalContentState.self, forKey: .terminal))
    }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .terminal(let state):
      try container.encode(ContentKind.terminal, forKey: .kind)
      try container.encode(state, forKey: .terminal)
    }
  }

  var kind: ContentKind {
    switch self {
    case .terminal: .terminal
    }
  }

  /// A brand-new seed of the same kind, carrying no restorable state.
  var freshSeed: ContentState {
    switch self {
    case .terminal: .terminal(TerminalContentState(workingDirectory: nil))
    }
  }

  /// True for content that must die with the app: a blocking-script runner's
  /// process has no zmx session to reattach.
  var isEphemeral: Bool {
    switch self {
    case .terminal(let state): state.launch?.bypassZmx == true
    }
  }
}

/// Identity of a tab's content, stable across hibernation and relaunch; the
/// zmx session name is derived from it for terminals.
nonisolated struct ContentID: Hashable, Identifiable, Codable, Sendable {
  let rawValue: UUID

  init() {
    rawValue = UUID()
  }

  init(rawValue: UUID) {
    self.rawValue = rawValue
  }

  var id: UUID { rawValue }

  init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(UUID.self)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// A tab's content: stable identity plus the kind-specific persisted state.
nonisolated struct ContentSnapshot: Equatable, Codable, Sendable {
  let id: ContentID
  let state: ContentState

  private enum CodingKeys: String, CodingKey {
    case id
    case state
  }

  var kind: ContentKind { state.kind }
}

/// One tab in a pane's strip, hosting exactly one content.
nonisolated struct TabItem: Equatable, Identifiable, Codable, Sendable {
  let id: TabID
  var title: String
  var customTitle: String?
  var icon: String?
  var tintColor: RepositoryColor?
  var content: ContentSnapshot
  /// Live-only: a locked (blocking-script) tab refuses renames and shows the
  /// lock marker for its whole life. Blocking tabs are never persisted, so this
  /// stays off the wire. The running vs parked distinction is the terminal's
  /// read-only state, not this flag.
  var isLocked = false

  private enum CodingKeys: String, CodingKey {
    case id
    case title
    case customTitle
    case icon
    case tintColor
    case content
  }

  init(
    id: TabID,
    title: String,
    customTitle: String? = nil,
    icon: String? = nil,
    tintColor: RepositoryColor? = nil,
    content: ContentSnapshot,
    isLocked: Bool = false
  ) {
    self.id = id
    self.title = title
    self.customTitle = customTitle
    self.icon = icon
    self.tintColor = tintColor
    self.content = content
    self.isLocked = isLocked
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(TabID.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
    icon = try container.decodeIfPresent(String.self, forKey: .icon)
    // `try?` so a tint value the running build doesn't recognize drops the
    // field, not the tab.
    tintColor = (try? container.decodeIfPresent(RepositoryColor.self, forKey: .tintColor)) ?? nil
    content = try container.decode(ContentSnapshot.self, forKey: .content)
  }

  /// Sanitized user-supplied tab title; nil (clears the override) when
  /// nothing printable remains.
  static func normalizedCustomTitle(_ title: String) -> String? {
    // Blank control scalars, not the whole control-characters set, so emoji joiners survive.
    let scalars = title.unicodeScalars.map { scalar in
      scalar.properties.generalCategory == .control || CharacterSet.newlines.contains(scalar)
        ? UnicodeScalar(" ") : scalar
    }
    let sanitized = String(String.UnicodeScalarView(scalars))
    let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

/// A split-tree leaf: an ordered strip of tabs with one selected.
nonisolated struct Pane: Equatable, Identifiable, Codable, Sendable {
  let id: PaneID
  var tabs: IdentifiedArrayOf<TabItem>
  var selectedTabID: TabID?

  private enum CodingKeys: String, CodingKey {
    case id
    case tabs
    case selectedTabID
  }

  init(id: PaneID, tabs: IdentifiedArrayOf<TabItem> = [], selectedTabID: TabID? = nil) {
    self.id = id
    self.tabs = tabs
    // Mirror decode's repair so both construction paths satisfy the invariant.
    self.selectedTabID = selectedTabID.flatMap { tabs[id: $0] != nil ? $0 : nil } ?? tabs.first?.id
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(PaneID.self, forKey: .id)
    // Element-wise so a tab a rollback build cannot read (a future content
    // kind) drops that tab, not the whole layout.
    let rawTabs = try container.decode([FailableDecodable<TabItem>].self, forKey: .tabs)
    // Duplicate tab IDs would trap IdentifiedArray; keep the first occurrence.
    var unique = IdentifiedArrayOf<TabItem>()
    for tab in rawTabs.compactMap(\.value) where unique[id: tab.id] == nil {
      unique.append(tab)
    }
    tabs = unique
    // Report dropped tabs so a destructive reader can refuse the partial file
    // rather than reap the missing session (its id is now absent).
    let droppedTabs = rawTabs.count - unique.count
    if droppedTabs > 0, let loss = decoder.userInfo[.layoutDecodeLoss] as? LayoutDecodeLoss {
      loss.droppedCount += droppedTabs
    }
    let decodedSelection = try container.decodeIfPresent(TabID.self, forKey: .selectedTabID)
    selectedTabID = decodedSelection.flatMap { unique[id: $0] != nil ? $0 : nil } ?? unique.first?.id
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(Array(tabs), forKey: .tabs)
    try container.encodeIfPresent(selectedTabID, forKey: .selectedTabID)
  }

  var selectedTab: TabItem? {
    selectedTabID.flatMap { tabs[id: $0] }
  }
}

/// Identity of a split-per-tab group (a top-level tab). Internal: never
/// accepted or printed by the CLI or deeplinks.
nonisolated struct PaneGroupID: Hashable, Identifiable, Codable, Sendable {
  let rawValue: UUID

  init(rawValue: UUID) {
    self.rawValue = rawValue
  }

  var id: UUID { rawValue }

  init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(UUID.self)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// A parked split-per-tab group: its own split tree (zoom included) and the
/// pane that takes focus when it becomes active.
nonisolated struct PaneGroup: Equatable, Identifiable, Codable, Sendable {
  let id: PaneGroupID
  var tree: SplitTree<PaneID>
  var focusedPaneID: PaneID
}

/// A worktree's whole layout: the split structure over panes, the panes
/// themselves, and focus. In tabsPerSplit the in-memory shape is the persisted
/// shape; a split-per-tab layout persists as its v2 fold plus a
/// `SplitPerTabSidecar`.
nonisolated struct PaneLayout: Equatable, Codable, Sendable {
  /// The ACTIVE group's tree (tabsPerSplit: the only tree).
  var tree: SplitTree<PaneID>
  /// Every pane of every group, flat.
  var panes: IdentifiedArrayOf<Pane>
  /// A leaf of `tree`.
  var focusedPaneID: PaneID?
  /// Split-per-tab only: the group `tree` belongs to. nil in tabsPerSplit and
  /// in an empty layout.
  var activeGroupID: PaneGroupID?
  /// Split-per-tab only: every group except the active one.
  var parkedGroups: IdentifiedArrayOf<PaneGroup> = []
  /// Split-per-tab only: every group id, active included, in strip order.
  var groupOrder: [PaneGroupID] = []

  private enum CodingKeys: String, CodingKey {
    case tree
    case panes
    case focusedPaneID
  }

  init(
    tree: SplitTree<PaneID> = SplitTree(),
    panes: IdentifiedArrayOf<Pane> = [],
    focusedPaneID: PaneID? = nil
  ) {
    self.tree = tree
    self.panes = panes
    // Mirror decode's repair so both construction paths satisfy the invariant.
    self.focusedPaneID =
      focusedPaneID.flatMap { panes[id: $0] != nil ? $0 : nil } ?? panes.first?.id
  }

  /// Memberwise, for conversions and tests: no focus repair, groups as given.
  init(
    tree: SplitTree<PaneID>,
    panes: IdentifiedArrayOf<Pane>,
    focusedPaneID: PaneID?,
    activeGroupID: PaneGroupID?,
    parkedGroups: IdentifiedArrayOf<PaneGroup>,
    groupOrder: [PaneGroupID]
  ) {
    self.tree = tree
    self.panes = panes
    self.focusedPaneID = focusedPaneID
    self.activeGroupID = activeGroupID
    self.parkedGroups = parkedGroups
    self.groupOrder = groupOrder
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    tree = try container.decode(SplitTree<PaneID>.self, forKey: .tree)
    let decodedPanes = try container.decode([Pane].self, forKey: .panes)
    var unique = IdentifiedArrayOf<Pane>()
    for pane in decodedPanes where unique[id: pane.id] == nil {
      unique.append(pane)
    }
    panes = unique
    // A dropped duplicate pane takes its tabs' session ids with it; mark the loss
    // so a destructive reader refuses the file rather than reap them.
    let droppedPanes = decodedPanes.count - unique.count
    if droppedPanes > 0, let loss = decoder.userInfo[.layoutDecodeLoss] as? LayoutDecodeLoss {
      loss.droppedCount += droppedPanes
    }
    let decodedFocus = try container.decodeIfPresent(PaneID.self, forKey: .focusedPaneID)
    focusedPaneID = decodedFocus.flatMap { unique[id: $0] != nil ? $0 : nil } ?? unique.first?.id
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    assert(activeGroupID == nil, "Encode the fold, not a split-per-tab layout.")
    try container.encode(tree, forKey: .tree)
    try container.encode(Array(panes), forKey: .panes)
    try container.encodeIfPresent(focusedPaneID, forKey: .focusedPaneID)
  }
}

nonisolated extension PaneLayout {
  /// The pane a tab lives in.
  func pane(containingTab tabID: TabID) -> Pane? {
    panes.first { $0.tabs[id: tabID] != nil }
  }

  /// The pane and tab hosting a content.
  func tab(containingContent contentID: ContentID) -> (pane: Pane, tab: TabItem)? {
    for pane in panes {
      if let tab = pane.tabs.first(where: { $0.content.id == contentID }) {
        return (pane, tab)
      }
    }
    return nil
  }

  /// Resolves a CLI / deeplink pane token: a pane's own id, or the id of a tab
  /// or content the pane hosts.
  func pane(forToken token: UUID) -> Pane? {
    if let pane = panes[id: PaneID(rawValue: token)] { return pane }
    if let pane = pane(containingTab: TabID(rawValue: token)) { return pane }
    if let resolved = tab(containingContent: ContentID(rawValue: token)) { return resolved.pane }
    return nil
  }

  /// Every content identity in the layout, tree order not guaranteed.
  var allContentIDs: [ContentID] {
    panes.flatMap { pane in pane.tabs.map(\.content.id) }
  }

  /// Structural invariants: the leaves of the active tree and of every parked
  /// group's tree are disjoint and agree with the panes one-to-one, panes are
  /// never empty (closing the last tab closes the pane), every selection
  /// resolves, focus is a leaf of the active tree and exists iff panes do, and
  /// the split-per-tab group bookkeeping agrees with itself. Decode repairs
  /// dangling references but does NOT reconcile tree against panes; loaders and
  /// the migrator gate on this predicate and fall back on failure.
  var isConsistent: Bool {
    let activeLeaves = tree.leaves()
    let leafIDs = activeLeaves + parkedGroups.flatMap { $0.tree.leaves() }
    guard Set(leafIDs).count == leafIDs.count else { return false }
    guard Set(leafIDs) == Set(panes.ids) else { return false }
    for pane in panes {
      guard !pane.tabs.isEmpty else { return false }
      guard let selected = pane.selectedTabID, pane.tabs[id: selected] != nil else { return false }
    }
    if let focusedPaneID {
      guard activeLeaves.contains(focusedPaneID) else { return false }
    } else if !panes.isEmpty {
      return false
    }
    let tabIDs = panes.flatMap { pane in pane.tabs.map(\.id) }
    guard Set(tabIDs).count == tabIDs.count else { return false }
    let contentIDs = allContentIDs
    guard Set(contentIDs).count == contentIDs.count else { return false }
    return hasConsistentGroups
  }

  /// The group half of `isConsistent`: no group state in tabsPerSplit; in
  /// split-per-tab a non-empty active tree, a duplicate-free strip order naming
  /// exactly the active and the parked groups, and parked groups that are
  /// non-empty with their focus on one of their own leaves.
  private var hasConsistentGroups: Bool {
    guard let activeGroupID else {
      return parkedGroups.isEmpty && groupOrder.isEmpty
    }
    guard !panes.isEmpty, !tree.isEmpty else { return false }
    guard Set(groupOrder).count == groupOrder.count else { return false }
    guard parkedGroups[id: activeGroupID] == nil else { return false }
    guard Set(groupOrder) == Set(parkedGroups.ids).union([activeGroupID]) else { return false }
    return parkedGroups.allSatisfy { group in
      !group.tree.isEmpty && group.tree.leaves().contains(group.focusedPaneID)
    }
  }

  /// Split-per-tab shape: every pane holds exactly one tab, and a non-empty
  /// layout has an active group.
  var isSplitPerTabShape: Bool {
    panes.allSatisfy { $0.tabs.count == 1 } && (panes.isEmpty || activeGroupID != nil)
  }

  /// The gate predicate: structure plus the shape the mode demands.
  func isConsistent(for mode: TerminalLayoutMode) -> Bool {
    switch mode {
    case .tabsPerSplit: isConsistent && activeGroupID == nil
    case .splitPerTab: isConsistent && isSplitPerTabShape
    }
  }
}

// MARK: - Split-per-tab groups.

nonisolated extension PaneLayout {
  /// The parked group holding a pane; nil when the pane is in the active tree
  /// (or unknown).
  func parkedGroupID(containingPane paneID: PaneID) -> PaneGroupID? {
    guard !tree.contains(paneID) else { return nil }
    return parkedGroups.first { $0.tree.contains(paneID) }?.id
  }

  /// The group holding a pane, active included; nil in tabsPerSplit.
  func groupID(containingPane paneID: PaneID) -> PaneGroupID? {
    guard let activeGroupID else { return nil }
    if tree.contains(paneID) { return activeGroupID }
    return parkedGroupID(containingPane: paneID)
  }

  /// A group's tree, active or parked.
  func tree(ofGroup id: PaneGroupID) -> SplitTree<PaneID>? {
    if id == activeGroupID { return tree }
    return parkedGroups[id: id]?.tree
  }

  /// A group's focused pane, active or parked.
  func focusedPaneID(ofGroup id: PaneGroupID) -> PaneID? {
    if id == activeGroupID { return focusedPaneID }
    return parkedGroups[id: id]?.focusedPaneID
  }

  /// 1-based strip position of a group.
  func groupIndex(of id: PaneGroupID) -> Int? {
    groupOrder.firstIndex(of: id).map { $0 + 1 }
  }

  /// Strip position clamped to 1...groupOrder.count, Ghostty goto_tab style.
  func groupID(atIndex index: Int) -> PaneGroupID? {
    guard !groupOrder.isEmpty else { return nil }
    return groupOrder[min(max(index, 1), groupOrder.count) - 1]
  }

  /// Next / previous group in strip order, wrapping; nil with fewer than 2.
  func groupID(relativeToActive forward: Bool) -> PaneGroupID? {
    guard groupOrder.count > 1, let activeGroupID,
      let index = groupOrder.firstIndex(of: activeGroupID)
    else { return nil }
    return groupOrder[forward ? groupOrder.indexWrapping(after: index) : groupOrder.indexWrapping(before: index)]
  }

  /// Swaps the parked group in: the outgoing active tree and focus become a
  /// parked PaneGroup (same id), the target's tree and focus become `tree` /
  /// `focusedPaneID`. groupOrder is unchanged. No-op for the active group or
  /// an unknown id.
  mutating func activateGroup(_ id: PaneGroupID) {
    guard let outgoingID = activeGroupID, id != outgoingID,
      let index = parkedGroups.index(id: id),
      let outgoingFocus = focusedPaneID
    else { return }
    let target = parkedGroups[index]
    // Park the outgoing group where the target sat, so a switch back restores
    // the same value.
    parkedGroups.remove(at: index)
    parkedGroups.insert(PaneGroup(id: outgoingID, tree: tree, focusedPaneID: outgoingFocus), at: index)
    tree = target.tree
    focusedPaneID = target.focusedPaneID
    activeGroupID = target.id
  }

  /// Runs `body` on the tree that holds `paneID` (active or parked) and writes
  /// it back. Returns nil when no tree holds the pane.
  mutating func modifyTree<R>(
    containing paneID: PaneID, _ body: (inout SplitTree<PaneID>) throws -> R
  ) rethrows -> R? {
    if tree.contains(paneID) {
      return try body(&tree)
    }
    guard let groupID = parkedGroupID(containingPane: paneID),
      var group = parkedGroups[id: groupID]
    else { return nil }
    let result = try body(&group.tree)
    parkedGroups[id: groupID] = group
    return result
  }

  /// Removes a leaf from whichever tree holds it and keeps the group
  /// bookkeeping consistent: an emptied parked group leaves the strip, a parked
  /// group whose focused leaf goes refocuses like a close would, and an emptied
  /// active tree promotes the neighbour group. Active focus otherwise stays put
  /// (the caller refocuses). Does not touch `panes`.
  mutating func removeLeaf(_ paneID: PaneID) {
    if let node = tree.find(id: paneID.rawValue) {
      tree = tree.removing(node)
      if tree.isEmpty, activeGroupID != nil {
        promoteNeighbourOfEmptiedActiveGroup()
      }
      return
    }
    guard let groupID = parkedGroupID(containingPane: paneID),
      var group = parkedGroups[id: groupID],
      let node = group.tree.find(id: paneID.rawValue)
    else { return }
    let target = group.tree.focusTargetAfterClosing(node)
    group.tree = group.tree.removing(node)
    guard let firstLeaf = group.tree.leaves().first else {
      parkedGroups.remove(id: groupID)
      groupOrder.removeAll { $0 == groupID }
      return
    }
    if group.focusedPaneID == paneID {
      group.focusedPaneID = target.flatMap { group.tree.contains($0) ? $0 : nil } ?? firstLeaf
    }
    parkedGroups[id: groupID] = group
  }

  /// The active tree just emptied: promote the neighbour group (ДР5), the one
  /// before it in strip order, else the one after it. Never goes through
  /// `activateGroup`, since an empty tree cannot be parked. With no parked group
  /// left the layout has no group at all.
  mutating func promoteNeighbourOfEmptiedActiveGroup() {
    guard let emptiedID = activeGroupID, tree.isEmpty else { return }
    let oldOrder = groupOrder
    groupOrder.removeAll { $0 == emptiedID }
    var neighbourID: PaneGroupID?
    if let index = oldOrder.firstIndex(of: emptiedID) {
      if index > oldOrder.startIndex {
        neighbourID = oldOrder[index - 1]
      } else if index + 1 < oldOrder.endIndex {
        neighbourID = oldOrder[index + 1]
      }
    }
    guard let neighbourID, let neighbour = parkedGroups.remove(id: neighbourID) else {
      activeGroupID = nil
      groupOrder = []
      focusedPaneID = nil
      return
    }
    tree = neighbour.tree
    focusedPaneID = neighbour.focusedPaneID
    activeGroupID = neighbour.id
  }

  /// v2 → split-per-tab (ВП2, АР3). Requires activeGroupID == nil (a
  /// split-per-tab layout comes back unchanged). The current split stays as
  /// group 1, each pane keeping only its selected tab; every other tab becomes
  /// its own one-pane group, in tree-leaf order and then strip order. Mints the
  /// active group id first, then a pane id and a group id per moved tab.
  func convertedToSplitPerTab(
    mintPaneID: () -> PaneID,
    mintGroupID: () -> PaneGroupID
  ) -> PaneLayout {
    guard activeGroupID == nil, !panes.isEmpty else { return self }
    var result = self
    let activeID = mintGroupID()
    result.activeGroupID = activeID
    result.groupOrder = [activeID]
    for leaf in tree.leaves() {
      guard var pane = result.panes[id: leaf],
        let selectedID = pane.selectedTabID ?? pane.tabs.first?.id,
        let selected = pane.tabs[id: selectedID]
      else { continue }
      let others = pane.tabs.filter { $0.id != selectedID }
      guard !others.isEmpty else { continue }
      pane.tabs = [selected]
      pane.selectedTabID = selectedID
      result.panes[id: leaf] = pane
      for tab in others {
        let paneID = mintPaneID()
        let groupID = mintGroupID()
        result.panes.append(Pane(id: paneID, tabs: [tab], selectedTabID: tab.id))
        result.parkedGroups.append(
          PaneGroup(id: groupID, tree: SplitTree(view: paneID), focusedPaneID: paneID)
        )
        result.groupOrder.append(groupID)
      }
    }
    return result
  }

  /// split-per-tab → v2 (ВП2). Returns the v2 layout and the pane ids it
  /// dissolved (every pane of every parked group). The active group's split,
  /// zoom and focus stay; every parked pane's tabs go to the end of the focused
  /// pane's strip in strip order, then tree-leaf order, and the focused pane's
  /// selection does not move.
  func convertedToTabsPerSplit() -> (layout: PaneLayout, dissolvedPaneIDs: Set<PaneID>) {
    guard let activeGroupID, let homeID = focusedPaneID, var home = panes[id: homeID] else {
      return (self, [])
    }
    var result = self
    var dissolved = Set<PaneID>()
    // Strip order first; a parked group missing from it still dissolves, so no
    // content is ever left behind.
    let parkedOrder: [PaneGroupID] =
      groupOrder.filter { $0 != activeGroupID }
      + parkedGroups.ids.filter { !groupOrder.contains($0) }
    for groupID in parkedOrder {
      guard let group = parkedGroups[id: groupID] else { continue }
      for leaf in group.tree.leaves() {
        guard let pane = result.panes.remove(id: leaf) else { continue }
        for tab in pane.tabs {
          home.tabs.append(tab)
        }
        dissolved.insert(leaf)
      }
    }
    result.panes[id: homeID] = home
    result.activeGroupID = nil
    result.parkedGroups = []
    result.groupOrder = []
    return (result, dissolved)
  }
}

nonisolated extension PaneLayout {
  /// The persistable layout: blocking-script tabs die with the app, so they
  /// (and any pane they empty, with its group when that was the group's last
  /// pane) drop, retargeting selection to the nearest left survivor.
  func strippingEphemeralContent() -> PaneLayout {
    var result = self
    for pane in panes {
      guard pane.tabs.contains(where: { $0.content.state.isEphemeral }) else { continue }
      var kept = IdentifiedArrayOf<TabItem>()
      var selected = pane.selectedTabID
      for tab in pane.tabs {
        if tab.content.state.isEphemeral {
          if selected == tab.id {
            selected = kept.last?.id
          }
        } else {
          kept.append(tab)
        }
      }
      guard !kept.isEmpty else {
        result.removeLeaf(pane.id)
        result.panes.remove(id: pane.id)
        continue
      }
      var survivor = pane
      survivor.tabs = kept
      survivor.selectedTabID = selected.flatMap { kept[id: $0] != nil ? $0 : nil } ?? kept.first?.id
      result.panes[id: pane.id] = survivor
    }
    if let focused = result.focusedPaneID, result.panes[id: focused] == nil {
      // Split-per-tab: `panes.first` can be a parked pane, so stay in the active tree.
      result.focusedPaneID =
        result.activeGroupID == nil ? result.panes.first?.id : result.tree.leaves().first
    }
    return result
  }
}

// MARK: - Split-per-tab persistence.

/// The split-per-tab grouping of a record whose `layout` is the v2 fold.
nonisolated struct SplitPerTabSidecar: Equatable, Codable, Sendable {
  var activeGroupID: PaneGroupID
  /// Every group id, active included, in strip order.
  var groupOrder: [PaneGroupID]
  /// Every parked group, with the panes the fold dissolved.
  var parkedGroups: [ParkedGroup]

  nonisolated struct ParkedGroup: Equatable, Codable, Sendable {
    let id: PaneGroupID
    /// The existing hand-written SplitTree wire format, zoom included.
    var tree: SplitTree<PaneID>
    var focusedPaneID: PaneID
    /// One entry per leaf of `tree`, leaf order.
    var panes: [PaneTab]
  }

  nonisolated struct PaneTab: Equatable, Codable, Sendable {
    let paneID: PaneID
    let tabID: TabID
  }
}

nonisolated extension PaneLayout {
  /// The persistable pair: the v2 projection (the SPT → v2 rule) plus the
  /// sidecar that rebuilds the groups. A v2 layout folds to (self, nil).
  /// Iterates `groupOrder` and tree-leaf order only, so the fold is
  /// deterministic and the writer's no-op gate holds.
  func foldedForPersistence() -> (layout: PaneLayout, sidecar: SplitPerTabSidecar?) {
    guard let activeGroupID else { return (self, nil) }
    let parked = groupOrder.compactMap { groupID -> SplitPerTabSidecar.ParkedGroup? in
      guard groupID != activeGroupID, let group = parkedGroups[id: groupID] else { return nil }
      let paneTabs = group.tree.leaves().compactMap { leaf in
        panes[id: leaf]?.tabs.first.map { SplitPerTabSidecar.PaneTab(paneID: leaf, tabID: $0.id) }
      }
      return SplitPerTabSidecar.ParkedGroup(
        id: group.id,
        tree: group.tree,
        focusedPaneID: group.focusedPaneID,
        panes: paneTabs
      )
    }
    let sidecar = SplitPerTabSidecar(
      activeGroupID: activeGroupID,
      groupOrder: groupOrder,
      parkedGroups: parked
    )
    return (convertedToTabsPerSplit().layout, sidecar)
  }

  /// Rebuilds the split-per-tab layout from a v2 base and its sidecar; nil when
  /// any check fails (ДР12). Pane order is canonical: the base panes in their
  /// stored order, then the parked panes in `groupOrder`, then tree-leaf order.
  func unfolding(_ sidecar: SplitPerTabSidecar) -> PaneLayout? {
    guard activeGroupID == nil, isConsistent else { return nil }
    guard Self.hasConsistentGroupIDs(sidecar) else { return nil }
    let entries = sidecar.parkedGroups.flatMap(\.panes)
    guard hasMovableEntries(entries) else { return nil }
    guard sidecar.parkedGroups.allSatisfy(Self.hasConsistentTree) else { return nil }
    // Move each sidecar tab out of its base pane.
    var result = self
    var movedTabs: [TabID: TabItem] = [:]
    for entry in entries {
      guard let owner = pane(containingTab: entry.tabID), var base = result.panes[id: owner.id] else {
        return nil
      }
      guard let tab = base.tabs.remove(id: entry.tabID) else { return nil }
      if base.selectedTabID == tab.id {
        base.selectedTabID = base.tabs.first?.id
      }
      result.panes[id: owner.id] = base
      movedTabs[tab.id] = tab
    }
    guard result.panes.allSatisfy({ !$0.tabs.isEmpty }) else { return nil }
    let sidecarGroups = Dictionary(
      sidecar.parkedGroups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
    )
    for groupID in sidecar.groupOrder where groupID != sidecar.activeGroupID {
      guard let group = sidecarGroups[groupID] else { return nil }
      let tabByPane = Dictionary(
        group.panes.map { ($0.paneID, $0.tabID) }, uniquingKeysWith: { first, _ in first }
      )
      for leaf in group.tree.leaves() {
        guard let tab = tabByPane[leaf].flatMap({ movedTabs[$0] }) else { return nil }
        result.panes.append(Pane(id: leaf, tabs: [tab], selectedTabID: tab.id))
      }
      result.parkedGroups.append(
        PaneGroup(id: group.id, tree: group.tree, focusedPaneID: group.focusedPaneID)
      )
    }
    result.activeGroupID = sidecar.activeGroupID
    result.groupOrder = sidecar.groupOrder
    guard result.isSplitPerTabShape, result.isConsistent(for: .splitPerTab) else { return nil }
    return result
  }

  /// Unfold check 2: unique parked ids (on the array, before any
  /// `IdentifiedArray` exists), and a duplicate-free strip order naming exactly
  /// the active and the parked groups.
  private static func hasConsistentGroupIDs(_ sidecar: SplitPerTabSidecar) -> Bool {
    let parkedIDs = sidecar.parkedGroups.map(\.id)
    guard Set(parkedIDs).count == parkedIDs.count else { return false }
    guard Set(sidecar.groupOrder).count == sidecar.groupOrder.count else { return false }
    guard sidecar.groupOrder.contains(sidecar.activeGroupID) else { return false }
    guard !parkedIDs.contains(sidecar.activeGroupID) else { return false }
    return Set(sidecar.groupOrder) == Set(parkedIDs).union([sidecar.activeGroupID])
  }

  /// Unfold checks 3 and 4: every tab exists in the base, once across the
  /// sidecar, and is never the focused pane's selected tab; every pane id is
  /// unique across the sidecar and new to the base.
  private func hasMovableEntries(_ entries: [SplitPerTabSidecar.PaneTab]) -> Bool {
    let tabIDs = entries.map(\.tabID)
    let paneIDs = entries.map(\.paneID)
    guard Set(tabIDs).count == tabIDs.count, Set(paneIDs).count == paneIDs.count else { return false }
    let focusedSelection = focusedPaneID.flatMap { panes[id: $0]?.selectedTabID }
    for entry in entries {
      guard pane(containingTab: entry.tabID) != nil, entry.tabID != focusedSelection else { return false }
      guard panes[id: entry.paneID] == nil else { return false }
    }
    return true
  }

  /// Unfold check 5: the tree's leaves are the group's panes, once each, and
  /// the focus is one of them.
  private static func hasConsistentTree(_ group: SplitPerTabSidecar.ParkedGroup) -> Bool {
    let leaves = group.tree.leaves()
    guard Set(leaves).count == leaves.count else { return false }
    guard Set(leaves) == Set(group.panes.map(\.paneID)) else { return false }
    return leaves.contains(group.focusedPaneID)
  }
}

/// Decodes a value or swallows its failure, so one unreadable element in a
/// collection drops that element rather than the container.
nonisolated struct FailableDecodable<Value: Decodable>: Decodable {
  let value: Value?

  init(from decoder: any Decoder) {
    value = try? Value(from: decoder)
  }
}

/// Accumulates content a tolerant layout decode silently dropped (unreadable
/// tabs, duplicate panes), so a destructive reader can treat the file as lossy
/// and keep the orphan reaper from sweeping sessions the dropped content still
/// owns. Install one in the decoder's `userInfo` under `.layoutDecodeLoss`.
///
/// `@unchecked Sendable`: a fresh box per decode, mutated only synchronously
/// within that single decode pass and never shared across threads.
nonisolated final class LayoutDecodeLoss: @unchecked Sendable {
  var droppedCount = 0
}

nonisolated extension CodingUserInfoKey {
  /// Carries a `LayoutDecodeLoss` through a layout decode.
  static let layoutDecodeLoss = CodingUserInfoKey(rawValue: "sh.supacode.layoutDecodeLoss")!
}
