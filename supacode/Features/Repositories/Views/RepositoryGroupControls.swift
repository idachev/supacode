import Sharing
import SupacodeSettingsShared
import SwiftUI

struct RepositoryGroupCreateButton: View {
  let send: (RepositoryGroup.Mutation) -> Void

  var body: some View {
    Button("New Repository Group…", systemImage: "folder.badge.plus") {
      send(.create(UUID(), "New Group"))
    }
    .help("Create a repository group. Rename it from its menu.")
  }
}

struct RepositoryGroupAssignmentMenu: View {
  let repositoryID: String
  let send: (RepositoryGroup.Mutation) -> Void
  @Shared(.settingsFile) private var settingsFile

  var body: some View {
    Menu("Move to Group", systemImage: "folder") {
      Button {
        send(.assign(repositoryID, nil))
      } label: {
        Label("Ungrouped", systemImage: currentGroupID == nil ? "checkmark" : "folder")
      }
      .help("Show this repository outside the groups")
      ForEach(settingsFile.repositoryGroups) { group in
        Button {
          send(.assign(repositoryID, group.id))
        } label: {
          Label(group.name, systemImage: currentGroupID == group.id ? "checkmark" : "folder")
        }
        .help("Move this repository to \(group.name)")
      }
      Divider()
      Button("New Group with This Repository…", systemImage: "folder.badge.plus") {
        let id = UUID()
        send(.create(id, "New Group"))
        send(.assign(repositoryID, id))
      }
      .help("Create a group containing this repository")
    }
    .help("Choose a group for this repository")
  }

  private var currentGroupID: UUID? {
    settingsFile.repositoryGroups.first { $0.repositoryIDs.contains(repositoryID) }?.id
  }
}

struct RepositoryGroupHeader: View {
  enum Surface { case sidebar, settings }
  let group: RepositoryGroup
  let surface: Surface
  let repositoryIDs: Set<String>
  let send: (RepositoryGroup.Mutation) -> Void
  @State private var isRenaming = false
  @State private var name = ""

  private var isCollapsed: Bool {
    surface == .sidebar ? group.sidebarCollapsed : group.settingsCollapsed
  }

  var body: some View {
    HStack {
      Button {
        send(
          surface == .sidebar
            ? .sidebarExpanded(group.id, isCollapsed)
            : .settingsExpanded(group.id, isCollapsed))
      } label: {
        HStack {
          Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
            .accessibilityHidden(true)
          Label(group.name, systemImage: "folder")
          Spacer()
          Text("\(group.repositoryIDs.intersection(repositoryIDs).count)")
            .foregroundStyle(.secondary)
        }
        .appFont(.body)
        .fontWeight(.semibold)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(isCollapsed ? "Expand \(group.name)" : "Collapse \(group.name)")
      Menu {
        Button("Rename Group…", systemImage: "pencil") {
          name = group.name
          isRenaming = true
        }
        .help("Change the group name")
        Button("Move All Repositories Here", systemImage: "folder.badge.plus") {
          send(.assignAll(repositoryIDs, group.id))
        }
        .help("Put all added repositories in this group")
        Button("Delete Group", systemImage: "trash", role: .destructive) {
          send(.remove(group.id))
        }
        .help("Delete the group and keep its repositories")
      } label: {
        Image(systemName: "ellipsis")
          .accessibilityLabel("Group options")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Manage \(group.name)")
    }
    .alert("Rename Repository Group", isPresented: $isRenaming) {
      TextField("Group name", text: $name)
      Button("Cancel", role: .cancel) {}
      Button("Save") { send(.rename(group.id, name)) }
        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .accessibilityElement(children: .contain)
  }
}
