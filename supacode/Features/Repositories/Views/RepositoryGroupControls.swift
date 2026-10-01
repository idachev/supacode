import CoreTransferable
import Sharing
import SupacodeSettingsShared
import SwiftUI
import UniformTypeIdentifiers

struct RepositoryGroupCreateButton: View {
  let request: () -> Void

  var body: some View {
    Button("New Repository Group…", systemImage: "folder.badge.plus") {
      request()
    }
    .help("Name and create a repository group")
  }
}

struct RepositoryGroupAssignmentMenu: View {
  let repositoryID: String
  let requestCreation: (String) -> Void
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
        requestCreation(repositoryID)
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
  @State private var isDropTargeted = false
  @State private var isHovering = false
  @State private var isConfirmingRemoval = false
  @State private var isConfirmingMoveAll = false

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
            .dropDestination(for: RepositoryGroupDragItem.self) { items, _ in
              let droppedIDs = Set(items.map(\.repositoryID)).intersection(repositoryIDs).subtracting(
                group.repositoryIDs)
              guard !droppedIDs.isEmpty else { return }
              send(.assignAll(droppedIDs, group.id))
            }
            .dropConfiguration { _ in DropConfiguration(operation: .move) }
            .onDropSessionUpdated { session in
              switch session.phase {
              case .entering, .active: isDropTargeted = true
              default: isDropTargeted = false
              }
            }

          Spacer()
          if isDropTargeted {
            Image(systemName: "plus")
              .foregroundStyle(.secondary)
              .accessibilityLabel("Move repository to group")
          } else {
            Text("\(group.repositoryIDs.intersection(repositoryIDs).count)")
              .foregroundStyle(.secondary)
          }
        }
        .appFont(.body)
        .fontWeight(.semibold)
        .foregroundStyle(Color.primary)
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
          isConfirmingMoveAll = true
        }
        .help("Put all added repositories in this group")
        Button("Delete Group", systemImage: "trash", role: .destructive) {
          isConfirmingRemoval = true
        }
        .help("Delete the group and keep its repositories")
      } label: {
        Image(systemName: "ellipsis")
          .accessibilityLabel("Group options")
          .frame(maxHeight: .infinity)
          .contentShape(Rectangle())
      }
      .menuStyle(.secondaryToolbar)
      .fixedSize()
      .help("Manage \(group.name)")
      .opacity(isHovering ? 1 : 0)
      .allowsHitTesting(isHovering)
    }
    .foregroundStyle(Color.primary)
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
    .background {
      RoundedRectangle(cornerRadius: 4)
        .fill(Color.accentColor.opacity(isDropTargeted ? 0.15 : 0))
    }
    .alert("Rename Repository Group", isPresented: $isRenaming) {
      TextField("Group name", text: $name)
      Button("Cancel", role: .cancel) {}
      Button("Save") { send(.rename(group.id, name)) }
        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .alert("Delete Repository Group?", isPresented: $isConfirmingRemoval) {
      Button("Cancel", role: .cancel) {}
      Button("Delete Group", role: .destructive) { send(.remove(group.id)) }
    } message: {
      Text("Delete “\(group.name)”? Its repositories will become ungrouped. Files on disk are untouched.")
    }
    .alert("Move All Repositories?", isPresented: $isConfirmingMoveAll) {
      Button("Cancel", role: .cancel) {}
      Button("Move All Repositories") { send(.assignAll(repositoryIDs, group.id)) }
    } message: {
      Text("Move all added repositories to “\(group.name)”? Repositories in other groups will leave those groups.")
    }
    .accessibilityElement(children: .contain)
  }
}

/// Present on the stable sidebar, since toolbar and context menus disappear
/// before their actions can present a text-input alert.
struct RepositoryGroupNamePrompt: ViewModifier {
  let draft: RepositoryGroupDraft?
  let send: (RepositoryGroupDraft.Action) -> Void

  func body(content: Content) -> some View {
    content.alert(
      "New Repository Group",
      isPresented: Binding(
        get: { draft != nil },
        set: { if !$0 { send(.cancel) } }
      )
    ) {
      TextField(
        "Group name",
        text: Binding(
          get: { draft?.name ?? "" },
          set: { send(.nameChanged($0)) }
        ))
      Button("Cancel", role: .cancel) { send(.cancel) }
      Button("Create") { send(.confirm) }
        .disabled(draft?.canSave != true)
    }
  }
}

/// A repository-only drag type keeps worktree reordering and file drops separate.
nonisolated struct RepositoryGroupDragItem: Codable, Transferable {
  let repositoryID: String

  /// Supply payload data to List's existing drag, without adding a competing
  /// drag gesture to a Section header.
  func itemProvider() -> NSItemProvider {
    let provider = NSItemProvider()
    provider.register(self)
    return provider
  }

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: UTType(exportedAs: "sh.supacode.repositoryId", conformingTo: .json))
  }
}

/// Settings rows use a standalone drag; the main sidebar uses native List dragging.
struct RepositoryGroupDragSource: ViewModifier {
  let repositoryID: String
  let name: String
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    content
      .contentShape(.dragPreview, .rect)
      .draggable(RepositoryGroupDragItem(repositoryID: repositoryID)) {
        Label(name, systemImage: "folder")
          .appFont(.body)
          .foregroundStyle(Color(nsColor: .labelColor))
          .fixedSize(horizontal: true, vertical: true)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
          .overlay {
            RoundedRectangle(cornerRadius: 6)
              .strokeBorder(.separator, lineWidth: 1)
          }
          .environment(\.colorScheme, colorScheme)
      }
      .dragConfiguration(
        DragConfiguration(
          operationsWithinApp: .init(allowCopy: false, allowMove: true),
          operationsOutsideApp: .init(allowCopy: false)
        )
      )
  }
}
