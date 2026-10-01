import Foundation

/// One level of user-defined organization shared by both repository lists.
public nonisolated struct RepositoryGroup: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public var repositoryIDs: Set<String>
  public var sidebarCollapsed: Bool
  public var settingsCollapsed: Bool

  public init(
    id: UUID = UUID(), name: String, repositoryIDs: Set<String> = [],
    sidebarCollapsed: Bool = false, settingsCollapsed: Bool = false
  ) {
    self.id = id
    self.name = name
    self.repositoryIDs = repositoryIDs
    self.sidebarCollapsed = sidebarCollapsed
    self.settingsCollapsed = settingsCollapsed
  }

  public enum Mutation: Equatable, Sendable {
    case create(UUID, String)
    case rename(UUID, String)
    case remove(UUID)
    case move(Set<UUID>, before: UUID?)
    case assign(String, UUID?)
    case assignAll(Set<String>, UUID)
    case sidebarExpanded(UUID, Bool)
    case settingsExpanded(UUID, Bool)
  }
}

extension SettingsFile {
  public mutating func updateRepositoryGroups(_ mutation: RepositoryGroup.Mutation) {
    switch mutation {
    case .create(let id, let name):
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, !repositoryGroups.contains(where: { $0.id == id }) else { return }
      repositoryGroups.append(RepositoryGroup(id: id, name: trimmed))
    case .rename(let id, let name):
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, let index = repositoryGroups.firstIndex(where: { $0.id == id }) else { return }
      repositoryGroups[index].name = trimmed
    case .move(let ids, let targetID):
      moveRepositoryGroups(ids, before: targetID)
    case .remove(let id):
      repositoryGroups.removeAll { $0.id == id }
    case .assign(let repositoryID, let groupID):
      guard groupID == nil || repositoryGroups.contains(where: { $0.id == groupID }) else { return }
      assignRepositories([repositoryID], to: groupID)
    case .assignAll(let repositoryIDs, let groupID):
      guard repositoryGroups.contains(where: { $0.id == groupID }) else { return }
      assignRepositories(repositoryIDs, to: groupID)
    case .sidebarExpanded(let id, let expanded):
      guard let index = repositoryGroups.firstIndex(where: { $0.id == id }) else { return }
      repositoryGroups[index].sidebarCollapsed = !expanded
    case .settingsExpanded(let id, let expanded):
      guard let index = repositoryGroups.firstIndex(where: { $0.id == id }) else { return }
      repositoryGroups[index].settingsCollapsed = !expanded
    }
  }

  private mutating func moveRepositoryGroups(_ ids: Set<UUID>, before targetID: UUID?) {
    guard !ids.isEmpty, targetID.map({ !ids.contains($0) }) ?? true,
      targetID.map({ id in repositoryGroups.contains { $0.id == id } }) ?? true
    else { return }
    let moving = repositoryGroups.filter { ids.contains($0.id) }
    guard !moving.isEmpty else { return }
    repositoryGroups.removeAll { ids.contains($0.id) }
    let destination =
      targetID.flatMap { id in repositoryGroups.firstIndex { $0.id == id } }
      ?? repositoryGroups.endIndex
    repositoryGroups.insert(contentsOf: moving, at: destination)
  }

  private mutating func assignRepositories(_ repositoryIDs: Set<String>, to groupID: UUID?) {
    for index in repositoryGroups.indices {
      repositoryGroups[index].repositoryIDs.subtract(repositoryIDs)
      if repositoryGroups[index].id == groupID {
        repositoryGroups[index].repositoryIDs.formUnion(repositoryIDs)
      }
    }
  }

}

/// Uncommitted input for the repository-group name prompt.
public nonisolated struct RepositoryGroupDraft: Equatable, Sendable {
  public var name: String
  public var repositoryID: String?

  public init(name: String = "", repositoryID: String? = nil) {
    self.name = name
    self.repositoryID = repositoryID
  }

  public var canSave: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  public enum Action: Equatable, Sendable {
    case request(String? = nil)
    case nameChanged(String)
    case confirm
    case cancel
  }
}
