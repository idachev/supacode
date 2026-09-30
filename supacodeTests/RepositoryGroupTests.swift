import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Sharing
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI
import Testing

@testable import supacode

@MainActor
struct RepositoryGroupTests {
  @Test func membershipHasOneLevelAndDeletionKeepsRepositories() {
    var file = SettingsFile(repositoryRoots: ["/tmp/a", "/tmp/b"])
    let first = UUID()
    let second = UUID()
    file.updateRepositoryGroups(.create(first, " Work "))
    file.updateRepositoryGroups(.create(second, "Personal"))
    file.updateRepositoryGroups(.assignAll(Set(file.repositoryRoots), first))
    #expect(file.repositoryGroups[0].name == "Work")
    #expect(file.repositoryGroups[0].repositoryIDs == Set(file.repositoryRoots))
    file.updateRepositoryGroups(.assign("/tmp/a", second))
    #expect(file.repositoryGroups[0].repositoryIDs == ["/tmp/b"])
    #expect(file.repositoryGroups[1].repositoryIDs == ["/tmp/a"])
    file.updateRepositoryGroups(.remove(first))
    #expect(file.repositoryRoots == ["/tmp/a", "/tmp/b"])
    #expect(file.repositoryGroups.count == 1)
    file.updateRepositoryGroups(.assign("/tmp/a", nil))
    #expect(file.repositoryGroups[0].repositoryIDs.isEmpty)
  }

  @Test func invalidNamesAndUnknownGroupsDoNotChangeMembership() {
    var file = SettingsFile()
    let id = UUID()
    file.updateRepositoryGroups(.create(id, "Work"))
    file.updateRepositoryGroups(.assign("/tmp/a", id))
    let original = file
    file.updateRepositoryGroups(.create(UUID(), " \n "))
    file.updateRepositoryGroups(.rename(id, " "))
    file.updateRepositoryGroups(.assign("/tmp/a", UUID()))
    file.updateRepositoryGroups(.assignAll(["/tmp/a"], UUID()))
    #expect(file == original)
  }

  @Test func routesRoundTripAndOldRoutesRemainCompatible() throws {
    var group = RepositoryGroup(name: "Work", repositoryIDs: ["/tmp/a", "remote:host:/repo"])
    group.sidebarCollapsed = true
    let routes = RoutesFile(local: ["/tmp/a"], repositoryGroups: [group])
    let decoded = try JSONDecoder().decode(RoutesFile.self, from: JSONEncoder().encode(routes))
    #expect(decoded == routes)
    let old = try JSONDecoder().decode(RoutesFile.self, from: Data(#"{"local":["/tmp/a"],"remote":[]}"#.utf8))
    #expect(old.repositoryGroups.isEmpty)
    let oldSettings = try JSONDecoder().decode(SettingsFile.self, from: Data("{}".utf8))
    #expect(oldSettings.repositoryGroups.isEmpty)
  }

  @Test(.dependencies) func splitSettingsStorePersistsGroups() throws {
    let storage = SettingsTestStorage()
    let id = UUID()
    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var file
      $file.withLock { $0.updateRepositoryGroups(.create(id, "Work")) }
    }
    let reloaded = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var file
      return file
    }
    #expect(reloaded.repositoryGroups.map(\.id) == [id])
  }

  @Test(.dependencies) func sidebarReducerUpdatesSharedGroupsAndVisibleHotkeys() async {
    let root = URL(fileURLWithPath: "/tmp/grouped-repo")
    let worktree = Worktree(
      id: WorktreeID(root.path()), name: "main", detail: "",
      workingDirectory: root, repositoryRootURL: root)
    let repository = Repository(
      id: RepositoryID(root.path()), rootURL: root,
      name: "grouped-repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.isInitialLoadComplete = true
    state.selection = .worktree(worktree.id)
    state.applyCacheRecomputes(.all)
    let store = TestStore(initialState: state) { RepositoriesFeature() }
    store.exhaustivity = .off
    let id = UUID()
    await store.send(.repositoryGroupsChanged(.create(id, "Work")))
    await store.send(.repositoryGroupsChanged(.assign(repository.id.rawValue, id)))
    #expect(store.state.sidebarStructure.sections.first?.id == .repositoryGroup(id))
    #expect(store.state.sidebarStructure.slotByID[worktree.id] != nil)
    await store.send(.repositoryGroupsChanged(.sidebarExpanded(id, false)))
    #expect(store.state.sidebarStructure.sections.count == 1)
    #expect(store.state.sidebarStructure.hotkeySlots.isEmpty)
    await store.send(.setAllSidebarGroupsExpanded(true))
    #expect(store.state.sidebarStructure.slotByID[worktree.id] != nil)
    await store.send(.setAllSidebarGroupsExpanded(false))
    #expect(store.state.sidebarStructure.hotkeySlots.isEmpty)
    await store.send(.revealSelectedWorktreeInSidebar)
    #expect(store.state.sidebarStructure.sections.contains { $0.repositoryID == repository.id })
    #expect(store.state.sidebarStructure.slotByID[worktree.id] != nil)
    #expect(store.state.pendingSidebarReveal?.worktreeID == worktree.id)
    await store.send(.repositoriesMoved([0], 1))
    @Shared(.settingsFile) var file
    #expect(file.repositoryGroups[0].repositoryIDs == [repository.id.rawValue])
  }

  @Test func dragAtGroupBoundaryUsesPreviousRepositoryInPersistedOrder() {
    let repoA: RepositoryID = "/tmp/repoA"
    let repoB: RepositoryID = "/tmp/repoB"
    let repoC: RepositoryID = "/tmp/repoC"
    let first = RepositoryGroup(name: "First", repositoryIDs: [repoA.rawValue, repoC.rawValue])
    let second = RepositoryGroup(name: "Second", repositoryIDs: [repoB.rawValue])
    var structure = SidebarStructure.empty
    structure.sections = [
      .repositoryGroup(first), .repository(repositoryID: repoA, groups: []),
      .repository(repositoryID: repoC, groups: []), .repositoryGroup(second),
      .repository(repositoryID: repoB, groups: []),
    ]
    structure.reorderableRepositoryIDs = [repoA, repoB, repoC]
    let move = structure.repositoryMove(offsets: [1], destination: 3)
    #expect(move?.offsets == [0])
    #expect(move?.destination == 3)
    var reordered = structure.reorderableRepositoryIDs
    if let move { reordered.move(fromOffsets: move.offsets, toOffset: move.destination) }
    #expect(reordered.filter { first.repositoryIDs.contains($0.rawValue) } == [repoC, repoA])
    let endMove = structure.repositoryMove(offsets: [1], destination: 5)
    #expect(endMove?.destination == 2)
    let headerMove = structure.repositoryMove(offsets: [0], destination: 2)
    #expect(headerMove?.offsets == nil)
    structure.sections = [
      .repositoryGroup(first), .repository(repositoryID: repoA, groups: []),
      .repository(repositoryID: repoC, groups: []), .repository(repositoryID: repoB, groups: []),
    ]
    let ungroupedBoundaryMove = structure.repositoryMove(offsets: [1], destination: 3)
    #expect(ungroupedBoundaryMove?.destination == 3)

  }

  @Test(.dependencies) func settingsReducerKeepsCollapseIndependentAndSharesMembership() async {
    @Shared(.settingsFile) var file
    let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }
    let id = UUID()
    await store.send(.repositoryGroupsChanged(.create(id, "Work")))
    await store.send(.repositoryGroupsChanged(.assign("/tmp/a", id)))
    await store.send(.repositoryGroupsChanged(.settingsExpanded(id, false)))
    #expect(file.repositoryGroups[0].repositoryIDs == ["/tmp/a"])
    #expect(file.repositoryGroups[0].settingsCollapsed)
    #expect(!file.repositoryGroups[0].sidebarCollapsed)
    await store.send(.repositoryGroupsChanged(.rename(id, "Renamed")))
    #expect(file.repositoryGroups[0].name == "Renamed")
  }
}
