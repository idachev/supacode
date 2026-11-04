import Foundation

/// Pure assembly of the `list` payload. The main-actor gatherer
/// (`RemoteSnapshotSource`) reads app state into these inputs; this type only
/// filters and orders, so the sidebar-matching rules are testable.
nonisolated enum RemoteSnapshotBuilder {
  struct RepositoryInput: Equatable, Sendable {
    let id: String
    let name: String
    var group: String?
    let worktrees: [WorktreeInput]
  }

  struct WorktreeInput: Equatable, Sendable {
    let id: String
    let name: String
    let branch: String
    let status: SidebarState.WorktreeStatus
    let focused: Bool
    let title: String?
    /// Position inside the worktree's sidebar bucket; nil when the sidebar has
    /// no row for it yet (it then sorts after the listed rows, in repository order).
    let sidebarIndex: Int?
    let tabs: [RemoteTab]
  }

  static func build(repositories: [RepositoryInput]) -> [RemoteRepository] {
    repositories.map { repository in
      let ordered = repository.worktrees.enumerated()
        .filter { !$0.element.status.isArchived }
        .sorted { lhs, rhs in
          sortKey(lhs.element, offset: lhs.offset) < sortKey(rhs.element, offset: rhs.offset)
        }
        .map(\.element)
      return RemoteRepository(
        id: repository.id,
        name: repository.name,
        group: repository.group,
        worktrees: ordered.map { worktree in
          RemoteWorktree(
            id: worktree.id,
            name: worktree.name,
            branch: worktree.branch,
            status: worktree.status.rawValue,
            focused: worktree.focused,
            title: worktree.title,
            working: worktree.tabs.contains(where: \.working),
            tabs: worktree.tabs
          )
        }
      )
    }
  }

  /// Sidebar order: main, then pinned, then unpinned; inside a group the
  /// sidebar's own order, then rows the sidebar does not list yet.
  private static func sortKey(_ worktree: WorktreeInput, offset: Int) -> SortKey {
    SortKey(rank: rank(of: worktree.status), sidebarIndex: worktree.sidebarIndex ?? Int.max, offset: offset)
  }

  private static func rank(of status: SidebarState.WorktreeStatus) -> Int {
    switch status {
    case .main: 0
    case .pinned: 1
    case .unpinned: 2
    case .archived: 3
    }
  }

  private struct SortKey: Comparable {
    let rank: Int
    let sidebarIndex: Int
    let offset: Int

    static func < (lhs: SortKey, rhs: SortKey) -> Bool {
      (lhs.rank, lhs.sidebarIndex, lhs.offset) < (rhs.rank, rhs.sidebarIndex, rhs.offset)
    }
  }
}
