import Foundation
import SupacodeSettingsShared

/// The remote window's sidebar as plain values (СЛ1–СЛ3): `list.sections` in the host's order,
/// repository rows by `rowIds`, and the load failures. Rows carry only plain values, so the
/// sidebar's leaf views can draw them without `Repository` / `Worktree` / `SidebarItemFeature`
/// state (СЛ2). Tabs are not rows: they show in the tab strip above the terminal.
nonisolated enum RemoteSidebarModel {
  /// One worktree row.
  struct Row: Equatable, Identifiable, Sendable {
    let id: String
    let repositoryID: String
    /// The repository's name, for the `repository · worktree` line of Active and Pinned rows.
    let repositoryName: String
    let name: String
    let branch: String
    let status: String
    let isWorking: Bool
    /// Every tab's agents, in tab order.
    let agents: [RemoteClientAgent]
    let canDelete: Bool
    /// The worktree's custom title (СЛ2), nil when it has none.
    var title: String?
  }

  enum Section: Equatable, Identifiable, Sendable {
    /// `active` or `pinned`: rows of any repository.
    case highlight(kind: String, title: String, rows: [Row])
    /// A repository group header and its repositories; `collapsed` is the Mac's state, a hint.
    /// `memberIDs` are the repository ids as the host sent them, before the filter: the section's
    /// identity does not change while the filter drops members.
    case group(title: String, collapsed: Bool, repositories: [Repository], memberIDs: [String])
    case repository(Repository)
    /// A repository the Mac could not read (`loadFailures`).
    case loadFailure(repositoryID: String, message: String)

    var id: String {
      switch self {
      case .highlight(let kind, _, _): "highlight:\(kind)"
      // Two groups may share a title; a repository is in one group only.
      case .group(let title, _, _, let memberIDs): "group:\(title)|\(memberIDs.joined(separator: ","))"
      case .repository(let repository): "repository:\(repository.id)"
      case .loadFailure(let repositoryID, _): "loadFailure:\(repositoryID)"
      }
    }

    /// The section's rows, top to bottom.
    var rows: [Row] {
      switch self {
      case .highlight(_, _, let rows): rows
      case .group(_, _, let repositories, _): repositories.flatMap(\.rows)
      case .repository(let repository): repository.rows
      case .loadFailure: []
      }
    }
  }

  struct Repository: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let canCreateWorktree: Bool
    let rows: [Row]
  }

  /// The Select Worktree N chord each row shows while ⌘ or ⌃ is held (НП4), by row id. `rowIDs`
  /// is `sidebarRowIDs`, the order `selectWorktree(slot:)` picks from: row N shows slot N's chord
  /// with the user's overrides; a disabled slot shows nothing, and an id listed twice keeps its first.
  /// Main actor, as `AppShortcuts`.
  @MainActor
  static func shortcutHints(
    rowIDs: [String], overrides: [AppShortcutID: AppShortcutOverride]
  ) -> [String: String] {
    var hints: [String: String] = [:]
    var seen = Set<String>()
    for (slot, id) in rowIDs.prefix(AppShortcuts.worktreeSelection.count).enumerated() {
      guard seen.insert(id).inserted,
        let hint = AppShortcuts.worktreeSelectionShortcutDisplay(atSlot: slot, overrides: overrides)
      else { continue }
      hints[id] = hint
    }
    return hints
  }

  /// `list.sections` in order, rows by `rowIds`, unresolvable ids skipped; `filter` keeps rows whose
  /// repository name, worktree name, branch, title or a tab title it matches, by the local sidebar's
  /// `SidebarFilter` rules (substring, or a few typos for a longer query; same as Android and web).
  /// While filtering, a repository, group or highlight left with no row is dropped; unfiltered, an
  /// empty repository stays (its header offers New Worktree). Load failures follow the sections.
  /// A list with no `sections` (an older host) shows every repository with all its worktrees.
  static func sections(_ list: RemoteClientList, filter: String) -> [Section] {
    let index = Index(list, filter: filter)
    var result: [Section] = []
    var seen = Set<String>()
    func append(_ section: Section?) {
      guard let section, seen.insert(section.id).inserted else { return }
      result.append(section)
    }
    if list.sections.isEmpty {
      for repository in list.repos {
        append(index.repository(repository.id, rowIDs: repository.worktrees.map(\.id)).map(Section.repository))
      }
    }
    for section in list.sections {
      switch section.kind {
      case "active", "pinned":
        let rows = (section.worktreeIds ?? []).compactMap(index.row)
        guard !index.isFiltering || !rows.isEmpty else { continue }
        append(.highlight(kind: section.kind, title: section.title ?? section.kind, rows: rows))
      case "group":
        let memberIDs = section.repositoryIds ?? []
        let repositories = memberIDs.compactMap { index.repository($0) }
        guard !index.isFiltering || !repositories.isEmpty else { continue }
        append(
          .group(
            title: section.title ?? "", collapsed: section.collapsed ?? false, repositories: repositories,
            memberIDs: memberIDs))
      case "repository":
        append(section.repositoryId.flatMap { index.repository($0) }.map(Section.repository))
      default:
        continue
      }
    }
    for failure in list.loadFailures where !failure.repositoryId.isEmpty {
      append(.loadFailure(repositoryID: failure.repositoryId, message: failure.message))
    }
    return result
  }

  /// The list's worktrees and repositories by id, and the filter.
  private struct Index {
    let worktrees: [String: (worktree: RemoteClientWorktree, repository: RemoteClientRepository)]
    let repositories: [String: RemoteClientRepository]
    /// Nil means no filter.
    let filter: SidebarFilter?

    var isFiltering: Bool { filter != nil }

    init(_ list: RemoteClientList, filter: String) {
      var worktrees: [String: (RemoteClientWorktree, RemoteClientRepository)] = [:]
      var repositories: [String: RemoteClientRepository] = [:]
      for repository in list.repos {
        if repositories[repository.id] == nil { repositories[repository.id] = repository }
        for worktree in repository.worktrees where worktrees[worktree.id] == nil {
          worktrees[worktree.id] = (worktree, repository)
        }
      }
      self.worktrees = worktrees
      self.repositories = repositories
      self.filter = SidebarFilter(query: filter)
    }

    /// The row of a worktree id that resolves and passes the filter.
    func row(_ worktreeID: String) -> Row? {
      guard let (worktree, repository) = worktrees[worktreeID], matches(worktree, in: repository) else {
        return nil
      }
      return Row(
        id: worktree.id,
        repositoryID: repository.id,
        repositoryName: repository.name,
        name: worktree.name,
        branch: worktree.branch,
        status: worktree.status,
        isWorking: worktree.working,
        agents: worktree.tabs.flatMap(\.agents),
        canDelete: worktree.canDeleteWorktree,
        title: worktree.title
      )
    }

    /// The repository with its rows (`rowIDs`, default its `rowIds`); nil when unknown, or when
    /// filtering left it no row.
    func repository(_ repositoryID: String, rowIDs: [String]? = nil) -> Repository? {
      guard let repository = repositories[repositoryID] else { return nil }
      let rows = (rowIDs ?? repository.rowIds).compactMap { id in
        worktrees[id]?.repository.id == repositoryID ? row(id) : nil
      }
      guard !isFiltering || !rows.isEmpty else { return nil }
      return Repository(
        id: repository.id, name: repository.name, canCreateWorktree: repository.canCreateWorktree, rows: rows)
    }

    private func matches(_ worktree: RemoteClientWorktree, in repository: RemoteClientRepository) -> Bool {
      guard let filter else { return true }
      let fields = [repository.name, worktree.name, worktree.branch, worktree.title] + worktree.tabs.map(\.title)
      return fields.contains { filter.matches($0) }
    }
  }
}
