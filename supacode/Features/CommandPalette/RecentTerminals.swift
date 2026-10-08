import Foundation
import IdentifiedCollections
import Sharing
import SupacodeSettingsShared

/// Typed AppStorage handle for the per-tab last-access log behind the
/// Recent Terminals palette: tab UUID string to epoch seconds.
nonisolated extension SharedKey where Self == AppStorageKey<[String: Double]>.Default {
  static var recentTerminalTabAccess: Self {
    Self[.appStorage("recentTerminalTabAccess"), default: [:]]
  }
}

/// The Recent Terminals palette surface: every terminal tab that still owns a
/// live zmx session, across all non-archived worktrees, most recently accessed
/// first. A tab exists in a worktree's layout exactly while its session lives
/// (closing a tab kills it), so the layouts are the source, not `zmx ls`.
enum RecentTerminals {
  private static let logger = SupaLogger("RecentTerminals")

  /// The tab the user is in for a worktree: the focused pane's selected tab.
  static func currentTabID(in layout: LayoutFeature.State?) -> TabID? {
    guard let layout, let paneID = layout.layout.focusedPaneID else { return nil }
    return layout.layout.panes[id: paneID]?.selectedTabID
  }

  /// Layout actions after which the selected worktree's current tab may differ.
  /// Title commits, resizes, and renames never move the selection, so they
  /// never count as an access.
  static func canChangeCurrentTab(_ action: LayoutFeature.Action) -> Bool {
    switch action {
    case .newTab, .splitPane, .closeTab, .closePane, .selectTab, .focusPane, .moveTab,
      .moveTabToSplit, .moveTabToSpanningSplit, .contentRequestedClose, .contentRequestedNewTab,
      .contentRequestedSplit, .contentRequestedFocus, .contentRequestedFocusSplit,
      .contentRequestedGotoTab:
      return true
    case .renameTab, .beginTabRename, .endTabRename, .enterWindowMode, .exitWindowMode, .resizePane,
      .equalizePanes, .toggleZoom, .hibernateTab, .wakeTab, .runtime, .contentRequestedToggleZoom,
      .contentRequestedResize, .contentRequestedMoveTab, .alert:
      return false
    }
  }

  /// Layout actions that can remove tabs, after which stale entries are pruned.
  static func canRemoveTabs(_ action: LayoutFeature.Action) -> Bool {
    switch action {
    case .closeTab, .closePane, .contentRequestedClose, .runtime(.killConfirmed), .alert:
      return true
    default:
      return false
    }
  }

  /// Stamps `tabID` as accessed at `date`.
  static func recordAccess(_ tabID: TabID, at date: Date) {
    @Shared(.recentTerminalTabAccess) var access
    $access.withLock { $0[tabID.rawValue.uuidString] = date.timeIntervalSince1970 }
  }

  /// Drops entries for tabs that no longer exist in any layout.
  static func prune(keeping liveTabIDs: Set<TabID>) {
    @Shared(.recentTerminalTabAccess) var access
    let liveKeys = Set(liveTabIDs.map(\.rawValue.uuidString))
    let pruned = access.filter { liveKeys.contains($0.key) }
    guard pruned.count != access.count else { return }
    logger.debug("Pruned \(access.count - pruned.count) recent terminal entries.")
    $access.withLock { $0 = pruned }
  }

  /// One palette row per live terminal tab. Order: tabs with an access stamp,
  /// newest first; then tabs whose worktree is in `worktreeMRU`, by its rank;
  /// then the rest in sidebar order. `priorityTier` carries that ordinal so the
  /// empty query keeps it. The current tab is listed but flagged
  /// `isCurrentWorktree`, so the default selection lands on the previous tab.
  static func items(
    from repositories: RepositoriesFeature.State,
    layouts: IdentifiedArrayOf<LayoutFeature.State>,
    access: [String: Double],
    resolveTitle: (TabItem) -> String,
    isDormant: (TabItem) -> Bool
  ) -> [CommandPaletteItem] {
    struct Candidate {
      let row: SidebarItemFeature.State
      let tab: TabItem
      let stamp: Double?
      let mruRank: Int?
      let ordinal: Int
    }
    let mruRank: [Worktree.ID: Int] = Dictionary(
      repositories.worktreeMRU.enumerated().map { ($1, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let archivedIDs = repositories.archivedWorktreeIDSet
    let selectedWorktreeID = repositories.selectedWorktreeID
    let currentTabID = selectedWorktreeID.flatMap { currentTabID(in: layouts[id: $0]) }
    var candidates: [Candidate] = []
    for row in repositories.orderedSidebarItems() where !archivedIDs.contains(row.id) {
      guard let layout = layouts[id: row.id] else { continue }
      for pane in layout.layout.panes {
        // Blocking-script tabs bypass zmx and die with the app: no session.
        for tab in pane.tabs where !tab.content.state.isEphemeral {
          candidates.append(
            Candidate(
              row: row,
              tab: tab,
              stamp: access[tab.id.rawValue.uuidString],
              mruRank: mruRank[row.id],
              ordinal: candidates.count
            )
          )
        }
      }
    }
    let ordered = candidates.sorted { lhs, rhs in
      switch (lhs.stamp, rhs.stamp) {
      case (let lhsStamp?, let rhsStamp?) where lhsStamp != rhsStamp: return lhsStamp > rhsStamp
      case (_?, nil): return true
      case (nil, _?): return false
      default: break
      }
      switch (lhs.mruRank, rhs.mruRank) {
      case (let lhsRank?, let rhsRank?) where lhsRank != rhsRank: return lhsRank < rhsRank
      case (_?, nil): return true
      case (nil, _?): return false
      default: return lhs.ordinal < rhs.ordinal
      }
    }
    return ordered.enumerated().map { index, candidate in
      let row = candidate.row
      let repositoryName = repositories.repositoryName(for: row.repositoryID) ?? row.name
      let worktreeName = SidebarDisplayName.resolved(custom: row.customTitle, fallback: row.name) ?? row.name
      var subtitle = row.isFolder ? repositoryName : "\(repositoryName) / \(worktreeName)"
      if isDormant(candidate.tab) {
        subtitle += " · Dormant"
      }
      return CommandPaletteItem(
        id: "terminal.\(candidate.tab.id.rawValue.uuidString)",
        title: resolveTitle(candidate.tab),
        subtitle: subtitle,
        kind: .terminalTab(row.id, candidate.tab.id),
        priorityTier: index,
        isCurrentWorktree: row.id == selectedWorktreeID && candidate.tab.id == currentTabID
      )
    }
  }
}
