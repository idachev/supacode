import ComposableArchitecture
import Foundation
import OrderedCollections
import SupacodeSettingsShared

/// Reads the live app state the phone's `list` needs: repositories and their
/// sidebar status from the app store, tabs from each worktree's layout, and
/// per-tab title / agents / working state from the content's `TabChrome`.
@MainActor
final class RemoteSnapshotSource {
  private let store: StoreOf<AppFeature>
  private let terminalManager: WorktreeTerminalManager

  init(store: StoreOf<AppFeature>, terminalManager: WorktreeTerminalManager) {
    self.store = store
    self.terminalManager = terminalManager
  }

  nonisolated deinit {}

  /// The full `list` payload: repositories plus the sidebar's sections.
  func listMessage(id: Int?) -> RemoteListMessage {
    var repos = repositories()
    let structure = store.repositories.sidebarStructure
    let hoisted = Set(structure.hoistedRowIDs.map(\.rawValue))
    var sidebarRows: [String: [String]] = [:]
    var sections: [RemoteSection] = []
    for section in structure.sections {
      switch section {
      case .highlight(let kind, let rowIDs):
        sections.append(
          RemoteSection(kind: kind.rawValue, title: kind.title, worktreeIds: rowIDs.map(\.rawValue)))
      case .repositoryGroup(let group):
        let members = repos.map(\.id).filter { group.repositoryIDs.contains($0) }
        sections.append(
          RemoteSection(kind: "group", title: group.name, collapsed: group.sidebarCollapsed, repositoryIds: members))
      case .repository(let repositoryID, let groups):
        sidebarRows[repositoryID.rawValue] = groups.flatMap(\.rowIDs).map(\.rawValue)
        if !structure.groupedRepositoryIDs.contains(repositoryID) {
          sections.append(RemoteSection(kind: "repository", repositoryId: repositoryID.rawValue))
        }
      case .folder(let repositoryID, let rowID):
        sidebarRows[repositoryID.rawValue] = [rowID.rawValue]
        if !structure.groupedRepositoryIDs.contains(repositoryID) {
          sections.append(RemoteSection(kind: "repository", repositoryId: repositoryID.rawValue))
        }
      case .failedRepository, .environmentBlockedRepository, .placeholder:
        continue
      }
    }
    // Repositories inside a collapsed group (or a collapsed section) render no
    // rows in the sidebar; give the phone their non-hoisted rows in list order.
    for index in repos.indices {
      repos[index].rowIds =
        sidebarRows[repos[index].id] ?? repos[index].worktrees.map(\.id).filter { !hoisted.contains($0) }
    }
    return RemoteListMessage(id: id, repos: repos, sections: sections)
  }

  func repositories() -> [RemoteRepository] {
    let state = store.repositories
    @Shared(.settingsFile) var settingsFile: SettingsFile
    let groups = settingsFile.repositoryGroups
    let inputs = state.repositories.map { repository in
      let section = state.sidebar.sections[repository.id]
      return RemoteSnapshotBuilder.RepositoryInput(
        id: repository.id.rawValue,
        name: SidebarDisplayName.resolved(custom: section?.title, fallback: repository.name) ?? repository.name,
        group: groups.first { $0.repositoryIDs.contains(repository.id.rawValue) }?.name,
        worktrees: repository.worktrees.map { worktree in
          let status = state.sidebar.status(
            of: worktree.id,
            in: repository.id,
            isMain: state.isMainWorktree(worktree)
          )
          let bucketID = state.sidebar.currentBucket(of: worktree.id, in: repository.id)
          let bucket = bucketID.flatMap { section?.buckets[$0] }
          let item = bucket?.items[worktree.id]
          return RemoteSnapshotBuilder.WorktreeInput(
            id: worktree.id.rawValue,
            name: worktree.name,
            branch: worktree.name,
            status: status,
            focused: worktree.id == state.selectedWorktreeID,
            title: item?.title,
            sidebarIndex: bucket?.items.index(forKey: worktree.id),
            tabs: tabs(of: worktree.id)
          )
        }
      )
    }
    return RemoteSnapshotBuilder.build(repositories: Array(inputs))
  }

  /// The live grid of a content's terminal, or nil when the content has no
  /// surface and no recorded grid yet.
  func gridSize(contentID: UUID) -> (columns: Int, rows: Int)? {
    let content = ContentRuntime.liveValue.content(for: ContentID(rawValue: contentID)) as? TerminalContent
    return content?.gridSize
  }

  /// Caps a phone-opened terminal the Mac does not show, so the phone does not
  /// get the whole Mac window's width. False while the terminal has no surface.
  func capNewTabGrid(contentID: UUID, columns: Int, rows: Int) -> Bool {
    let content = ContentRuntime.liveValue.content(for: ContentID(rawValue: contentID)) as? TerminalContent
    return content?.capUnmountedGrid(maxColumns: columns, maxRows: rows) ?? false
  }

  /// Whether the terminal refuses input (a completed blocking script's parked
  /// shell); the phone must not type where the Mac would not.
  func isReadOnly(contentID: UUID) -> Bool {
    let chrome = ContentRuntime.liveValue.content(for: ContentID(rawValue: contentID))?.chrome as? TerminalTabChrome
    return chrome?.isReadOnly ?? false
  }

  /// Whether any worktree currently lists this content as a tab.
  func containsContent(_ contentID: UUID) -> Bool {
    store.repositories.repositories.contains { repository in
      repository.worktrees.contains { worktree in
        terminalManager.layoutState(for: worktree.id)?.layout.allContentIDs
          .contains(ContentID(rawValue: contentID)) ?? false
      }
    }
  }

  /// Asks the owning layout to wake the tab of a content whose session has
  /// not started yet (a worktree not opened since launch), the way selecting
  /// it from the CLI does. Returns false when no worktree lists the content.
  func wake(contentID: UUID) -> Bool {
    let content = ContentID(rawValue: contentID)
    for repository in store.repositories.repositories {
      for worktree in repository.worktrees {
        guard let tab = terminalManager.layoutState(for: worktree.id)?.layout.tab(containingContent: content)?.tab
        else { continue }
        terminalManager.sendLayout(worktree.id, .wakeTab(id: tab.id))
        return true
      }
    }
    return false
  }

  /// Opens one new terminal tab (the default shell, the worktree's directory)
  /// in a worktree through the terminal command the app's "new tab" action
  /// sends, in the background: the tab is not selected and the window keeps
  /// its worktree. Returns the minted tab id (also its content id), or why
  /// no tab was requested. The tab lands asynchronously; poll `contentID(ofTab:in:)`.
  func requestNewTab(worktreeID raw: String) -> Result<UUID, RemoteTabNewRejection> {
    let state = store.repositories
    var found: (worktree: Worktree, isArchived: Bool)?
    for repository in state.repositories {
      guard let worktree = repository.worktrees.first(where: { $0.id.rawValue == raw }) else { continue }
      let status = state.sidebar.status(of: worktree.id, in: repository.id, isMain: state.isMainWorktree(worktree))
      found = (worktree, status.isArchived)
      break
    }
    if let rejection = RemoteTabNewRejection.check(
      found: found != nil, isArchived: found?.isArchived ?? false, isMissing: found?.worktree.isMissing ?? false)
    {
      return .failure(rejection)
    }
    guard let worktree = found?.worktree else { return .failure(.unknownWorktree) }
    let tabID = UUID()
    // Same setup-script rule as `AppFeature`'s `.newTerminalInWorktree`.
    let runSetupScript = state.sidebarItems[id: worktree.id]?.lifecycle == .pending
    // The worktree's own directory, not the focused terminal's (a remote
    // worktree's shell starts on the remote, where this is ignored).
    terminalManager.handleCommand(
      .createTab(
        worktree, runSetupScriptIfNew: runSetupScript, id: tabID, focusing: false,
        workingDirectory: Self.newTabDirectory(for: worktree)))
    return .success(tabID)
  }

  /// Where a phone-opened tab starts: the worktree's directory for a local
  /// worktree, nil (the remote shell's own) for a remote one.
  nonisolated static func newTabDirectory(for worktree: Worktree) -> String? {
    worktree.host == nil ? worktree.workingDirectory.path(percentEncoded: false) : nil
  }

  /// The content of a tab once the worktree's layout lists it (what `attach`
  /// needs); nil until then.
  func contentID(ofTab tabID: UUID, in worktreeRaw: String) -> UUID? {
    let tab = TabID(rawValue: tabID)
    for repository in store.repositories.repositories {
      guard let worktree = repository.worktrees.first(where: { $0.id.rawValue == worktreeRaw }) else { continue }
      let layout = terminalManager.layoutState(for: worktree.id)?.layout
      return layout?.pane(containingTab: tab)?.tabs[id: tab]?.content.id.rawValue
    }
    return nil
  }

  private func tabs(of worktreeID: Worktree.ID) -> [RemoteTab] {
    guard let layout = terminalManager.layoutState(for: worktreeID)?.layout else { return [] }
    return Self.tabs(in: layout, runtime: ContentRuntime.liveValue)
  }

  /// Every terminal tab of a layout in flat pane order (parked split-per-tab
  /// groups included), with the title the strip shows and the agents, working
  /// and read-only state from the content's chrome. A tab whose content is not
  /// registered yet (never started) reports no agents and not working.
  static func tabs(in layout: PaneLayout, runtime: ContentRuntime) -> [RemoteTab] {
    let focusedTabID = layout.focusedPaneID.flatMap { layout.panes[id: $0]?.selectedTabID }
    return layout.panes.flatMap { pane in
      pane.tabs.filter { $0.content.kind == .terminal }.map { tab in
        let chrome = runtime.content(for: tab.content.id)?.chrome as? TerminalTabChrome
        return RemoteTab(
          id: tab.id.rawValue.uuidString,
          contentId: tab.content.id.rawValue.uuidString,
          title: TabTitle.resolved(for: tab, chrome: chrome),
          focused: tab.id == focusedTabID,
          working: chrome?.isWorking ?? false,
          readOnly: chrome?.isReadOnly ?? false,
          agents: (chrome?.agents ?? []).map {
            RemoteAgent(agent: $0.agent.rawValue, activity: $0.activity.rawValue)
          }
        )
      }
    }
  }
}

/// Why a `tab.new` opened no tab; `message` is what the phone is told.
nonisolated enum RemoteTabNewRejection: Error, Equatable, Sendable {
  case unknownWorktree
  case archivedWorktree
  case missingWorktree

  var message: String {
    switch self {
    case .unknownWorktree: "no such worktree"
    case .archivedWorktree: "the worktree is archived"
    case .missingWorktree: "the worktree directory is missing"
    }
  }

  /// The rejection for a worktree lookup, or nil when a tab may be opened.
  static func check(found: Bool, isArchived: Bool, isMissing: Bool) -> Self? {
    guard found else { return .unknownWorktree }
    if isArchived { return .archivedWorktree }
    if isMissing { return .missingWorktree }
    return nil
  }
}
