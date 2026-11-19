import ComposableArchitecture
import Sharing
import SupacodeSettingsShared
import SwiftUI

/// The remote window's sidebar (ОБ1): the Mac's `list.sections` as local Supacode draws its own,
/// repository by repository with worktree rows (no tab rows), under the filter field. The list
/// reads the cached sections; each row draws only the plain values of its `Row`, so a pushed
/// `list` re-renders only the rows whose values changed.
struct RemoteSidebarView: View {
  @Bindable var store: StoreOf<RemoteClientFeature>
  var isFilterFocused: FocusState<Bool>.Binding
  /// The effective "Filter Sidebar" shortcut, shown in the field's tooltip.
  let filterShortcut: AppShortcut?
  /// Hands the keyboard back to the selected terminal (Esc in the filter field).
  let focusTerminal: () -> Void

  @Shared(.appStorage("worktreeRowHideSubtitleOnMatch")) private var hideSubtitleOnMatch = true

  var body: some View {
    let sections = store.sidebarSections
    let busy = store.busyRequests
    let selectedID = store.selectedWorktreeID
    let selection = Binding<String?>(
      get: { selectedID },
      set: { id in
        guard let id, id != selectedID else { return }
        store.send(.worktreeSelected(id))
      }
    )
    List(selection: selection) {
      ForEach(sections) { section in
        RemoteSidebarSectionView(
          section: section, busyRequests: busy, hideSubtitleOnMatch: hideSubtitleOnMatch, store: store)
      }
    }
    .listStyle(.sidebar)
    .overlay {
      let query = store.filterText.trimmingCharacters(in: .whitespacesAndNewlines)
      if sections.isEmpty, !query.isEmpty {
        ContentUnavailableView.search(text: query)
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      SidebarFilterField(
        query: $store.filterText.sending(\.filterChanged),
        isFocused: isFilterFocused,
        shortcut: filterShortcut,
        onEscape: {
          store.send(.filterChanged(""))
          focusTerminal()
        }
      )
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if store.list?.canRefreshWorktrees == true {
        RemoteSidebarRefreshButton(
          isBusy: busy.contains(RemoteClientFeature.RequestKey.make("worktrees.refresh", nil))
        ) {
          store.send(.refreshTapped)
        }
      }
    }
  }
}

/// One section of the Mac's sidebar.
private struct RemoteSidebarSectionView: View {
  /// How far a group's repositories sit in from the group row, as in the local sidebar.
  static let groupMemberIndent: CGFloat = 12

  let section: RemoteSidebarModel.Section
  let busyRequests: Set<String>
  let hideSubtitleOnMatch: Bool
  let store: StoreOf<RemoteClientFeature>

  var body: some View {
    switch section {
    case .highlight(let kind, let title, let rows):
      Section {
        ForEach(rows) { row in
          rowView(row, isHighlighted: true)
        }
      } header: {
        HStack(spacing: 4) {
          Text(title)
          SidebarHighlightHeaderDot(color: kind == "pinned" ? .orange : .blue)
        }
        .appFontInheriting(.subheadline, weight: .semibold)
      }
    case .group(let title, _, let repositories, _):
      RemoteSidebarGroupRow(title: title, count: repositories.count)
      ForEach(repositories) { repository in
        repositorySection(repository, indent: Self.groupMemberIndent)
      }
    case .repository(let repository):
      repositorySection(repository, indent: 0)
    case .loadFailure(_, let message):
      Section {
        Label {
          Text("Cannot be read on the Mac: \(message)")
            .appFont(.footnote)
            .foregroundStyle(.secondary)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
        }
        .selectionDisabled()
      } header: {
        EmptyView()
      }
    }
  }

  private func repositorySection(_ repository: RemoteSidebarModel.Repository, indent: CGFloat) -> some View {
    let createKey = RemoteClientFeature.RequestKey.make("worktree.new", repository.id)
    return Section {
      ForEach(repository.rows) { row in
        rowView(row, isHighlighted: false)
          .padding(.leading, indent)
      }
    } header: {
      RepoSectionHeaderView(name: repository.name, customTitle: nil, color: nil, isRemoving: false)
        .padding(.leading, indent)
    }
    .sectionActions {
      if repository.canCreateWorktree {
        RemoteNewWorktreeButton(repositoryName: repository.name, isBusy: busyRequests.contains(createKey)) {
          store.send(.newWorktreeTapped(repositoryID: repository.id))
        }
      }
    }
  }

  private func rowView(_ row: RemoteSidebarModel.Row, isHighlighted: Bool) -> some View {
    RemoteSidebarRow(
      row: row,
      isHighlighted: isHighlighted,
      hideSubtitleOnMatch: hideSubtitleOnMatch,
      isDeleting: busyRequests.contains(RemoteClientFeature.RequestKey.make("worktree.delete", row.id)),
      store: store
    )
    .equatable()
    .tag(row.id)
  }
}

/// A repository group of the Mac: its name and how many repositories show under it. The Mac's
/// collapsed state is not mirrored; the group always shows its repositories.
private struct RemoteSidebarGroupRow: View {
  let title: String
  let count: Int

  var body: some View {
    HStack {
      Label(title, systemImage: "folder")
      Spacer()
      Text("\(count)")
        .foregroundStyle(.secondary)
        .padding(.trailing, 4)
    }
    .appFont(.body)
    .fontWeight(.semibold)
    .selectionDisabled()
  }
}

/// One worktree row, drawn from its plain values only. `==` ignores the store, which the row
/// only sends to.
private struct RemoteSidebarRow: View, Equatable {
  let row: RemoteSidebarModel.Row
  /// In Active / Pinned: the subtitle reads `repository · worktree`.
  let isHighlighted: Bool
  let hideSubtitleOnMatch: Bool
  let isDeleting: Bool
  let store: StoreOf<RemoteClientFeature>

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.row == rhs.row && lhs.isHighlighted == rhs.isHighlighted
      && lhs.hideSubtitleOnMatch == rhs.hideSubtitleOnMatch && lhs.isDeleting == rhs.isDeleting
  }

  var body: some View {
    let isMain = row.status == "main"
    let resolved = ResolvedRowDisplay(
      kind: .gitWorktree,
      branchName: row.branch,
      worktreeName: isMain ? nil : row.name,
      isMainWorktree: isMain,
      isPinned: row.status == "pinned",
      hideSubtitle: false,
      hideSubtitleOnMatch: hideSubtitleOnMatch,
      highlightSubtitle: isHighlighted
        ? SidebarHighlightRepoTag(repoName: row.repositoryName, repoColor: nil, hostInfo: nil) : nil,
      customTitle: row.title
    )
    Label {
      HStack(spacing: 8) {
        TitleView(
          name: resolved.name,
          subtitle: resolved.subtitle,
          accent: resolved.accent,
          customTint: nil,
          isLifecycleBusy: isDeleting,
          isTaskRunning: row.isWorking
        )
        .equatable()
        Spacer(minLength: 0)
        RemoteAgentBadges(agents: row.agents, size: 16)
          .fixedSize(horizontal: true, vertical: false)
      }
    } icon: {
      IconContent(
        isFolder: false,
        isRemote: false,
        isMissing: false,
        icon: .branch,
        checkBadgeState: nil,
        reviewDecision: nil,
        rowState: isDeleting ? .deleting : .idle
      )
      .equatable()
    }
    .labelStyle(.verticallyCentered)
    .listRowInsets(.trailing, 4)
    .listRowInsets(.vertical, 6)
    .contextMenu {
      if row.canDelete {
        Button("Delete Worktree…", systemImage: "trash", role: .destructive) {
          store.send(.deleteWorktreeTapped(worktreeID: row.id))
        }
        .help("Delete this worktree on the Mac; its branch stays")
        .disabled(isDeleting)
      }
    }
  }
}

/// The agents of a remote row or tab, as the local avatar group draws them: attention first. An
/// agent or activity this Mac's Supacode does not know is left out rather than guessed.
struct RemoteAgentBadges: View {
  let agents: [RemoteClientAgent]
  let size: CGFloat

  var body: some View {
    let instances = Self.instances(agents)
    if !instances.isEmpty {
      AgentAvatarGroupView(instances: instances, size: size)
    }
  }

  static func instances(_ agents: [RemoteClientAgent]) -> [AgentPresenceFeature.AgentInstance] {
    let known = agents.compactMap { agent -> AgentPresenceFeature.AgentInstance? in
      guard let kind = SkillAgent(rawValue: agent.agent),
        let activity = AgentPresenceFeature.Activity(rawValue: agent.activity)
      else { return nil }
      return AgentPresenceFeature.AgentInstance(agent: kind, activity: activity)
    }
    // Stable: attention first, the rest in the Mac's tab order.
    return known.filter(\.activity.isAttention) + known.filter { !$0.activity.isAttention }
  }
}

/// The repository header's "+": New Worktree… on the Mac.
private struct RemoteNewWorktreeButton: View {
  let repositoryName: String
  let isBusy: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "plus")
        .accessibilityLabel("New Worktree")
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isBusy)
    .foregroundStyle(.secondary)
    .help(
      isBusy ? "Creating a worktree in \(repositoryName) on the Mac…" : "New Worktree in \(repositoryName) on the Mac"
    )
    .padding(.trailing, 4)
  }
}

/// Refresh Worktrees on the Mac, under the list.
private struct RemoteSidebarRefreshButton: View {
  let isBusy: Bool
  let action: () -> Void

  var body: some View {
    HStack {
      Button(action: action) {
        Label("Refresh Worktrees", systemImage: "arrow.clockwise")
      }
      .buttonStyle(.borderless)
      .disabled(isBusy)
      .help("Refresh Worktrees: the Mac reads its repositories again")
      if isBusy {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Refreshing worktrees")
      }
      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }
}
