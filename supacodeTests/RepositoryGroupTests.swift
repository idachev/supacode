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
    #expect(store.state.sidebarStructure.groupedRepositoryIDs == [repository.id])
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
    let destinationID = UUID()
    await store.send(.repositoryGroupsChanged(.create(destinationID, "Destination")))
    await store.send(.repositoryGroupsChanged(.sidebarExpanded(destinationID, false)))
    await store.send(.repositoryGroupsChanged(.assignAll([repository.id.rawValue], destinationID)))
    #expect(file.repositoryGroups[0].repositoryIDs.isEmpty)
    #expect(file.repositoryGroups[1].repositoryIDs == [repository.id.rawValue])
    #expect(file.repositoryGroups[1].sidebarCollapsed)
    #expect(store.state.sidebarStructure.hotkeySlots.isEmpty)

  }

  @Test(arguments: [false, true])
  func repositoryDropUsesTargetIdentityWithInterleavedGroups(after: Bool) {
    let repoA: RepositoryID = "/tmp/repoA"
    let repoB: RepositoryID = "/tmp/repoB"
    let repoC: RepositoryID = "/tmp/repoC"
    let repoD: RepositoryID = "/tmp/repoD"
    let group = RepositoryGroup(name: "Work", repositoryIDs: [repoA.rawValue, repoC.rawValue, repoD.rawValue])
    var structure = SidebarStructure.empty
    structure.sections = [
      .highlight(kind: .pinned, rowIDs: []), .repositoryGroup(group),
      .repository(repositoryID: repoA, groups: []),
      .repository(repositoryID: repoC, groups: []),
      .repository(repositoryID: repoD, groups: []),
      .folder(repositoryID: repoB, rowID: "/tmp/repoB"),
    ]
    structure.reorderableRepositoryIDs = [repoA, repoB, repoC, repoD]
    let move = structure.repositoryMove(repositoryIDs: [repoA], relativeTo: repoC, after: after)
    #expect(move?.offsets == [0])
    #expect(move?.destination == (after ? 3 : 2))
    var reordered = structure.reorderableRepositoryIDs
    if let move { reordered.move(fromOffsets: move.offsets, toOffset: move.destination) }
    #expect(reordered == (after ? [repoB, repoC, repoA, repoD] : [repoB, repoA, repoC, repoD]))

    let upward = structure.repositoryMove(repositoryIDs: [repoD], relativeTo: repoC, after: after)
    var upwardOrder = structure.reorderableRepositoryIDs
    if let upward { upwardOrder.move(fromOffsets: upward.offsets, toOffset: upward.destination) }
    #expect(upwardOrder == (after ? [repoA, repoB, repoC, repoD] : [repoA, repoB, repoD, repoC]))
  }

  @Test func repositoryDropIgnoresSelfAndUnknownTargets() {
    let repoA: RepositoryID = "/tmp/repoA"
    let repoB: RepositoryID = "/tmp/repoB"
    let repoC: RepositoryID = "/tmp/repoC"
    var structure = SidebarStructure.empty
    structure.reorderableRepositoryIDs = [repoA, repoB, repoC]
    #expect(structure.repositoryMove(repositoryIDs: [repoA], relativeTo: repoA, after: true) == nil)
    #expect(structure.repositoryMove(repositoryIDs: [repoA], relativeTo: "/tmp/stale", after: false) == nil)
    #expect(structure.repositoryMove(repositoryIDs: ["/tmp/stale"], relativeTo: repoB, after: false) == nil)
    #expect(structure.repositoryMove(repositoryIDs: [], relativeTo: repoB, after: true) == nil)
    let multiple = structure.repositoryMove(
      repositoryIDs: [repoB, repoC, "/tmp/stale"], relativeTo: repoA, after: false)
    #expect(multiple?.offsets == [1, 2])
    #expect(multiple?.destination == 0)
  }

  @Test func assigningRepositoryToItsCurrentGroupDoesNotChangeSettings() {
    let group = RepositoryGroup(name: "Work", repositoryIDs: ["/tmp/a", "/tmp/b"])
    var settings = SettingsFile()
    settings.repositoryGroups = [group]
    let original = settings
    settings.updateRepositoryGroups(.assignAll(["/tmp/a"], group.id))
    #expect(settings == original)
  }

  @Test(.dependencies, arguments: [false, true], [false, true])
  func repositoryDropUpdatesMembershipAndOrderTogether(after: Bool, targetIsGrouped: Bool) async {
    @Shared(.settingsFile) var settings
    @Shared(.sidebarSectionSort) var sectionSort: SidebarSectionSort
    $sectionSort.withLock { $0 = .manual }
    let repositories = ["a", "b", "c", "d"].map { name in
      let root = URL(fileURLWithPath: "/tmp/drop-\(name)")
      return Repository(id: RepositoryID(root.path()), rootURL: root, name: name, worktrees: [])
    }
    let ids = repositories.map(\.id)
    let sourceGroup = RepositoryGroup(name: "Source", repositoryIDs: [ids[0].rawValue])
    let targetGroup = RepositoryGroup(name: "Target", repositoryIDs: Set(ids.dropFirst().map(\.rawValue)))
    $settings.withLock { $0.repositoryGroups = targetIsGrouped ? [sourceGroup, targetGroup] : [sourceGroup] }
    var state = RepositoriesFeature.State(reconciledRepositories: repositories)
    state.isInitialLoadComplete = true
    state.applyCacheRecomputes(.all)
    let store = TestStore(initialState: state) { RepositoriesFeature() }
    store.exhaustivity = .off
    await store.send(.repositoryDropped([ids[0]], relativeTo: ids[2], after: after))
    let expected = after ? [ids[1], ids[2], ids[0], ids[3]] : [ids[1], ids[0], ids[2], ids[3]]
    #expect(store.state.orderedRepositoryIDs() == expected)
    #expect(store.state.sidebarStructure.sections.compactMap(\.repositoryID) == expected)
    #expect(settings.repositoryGroups[0].repositoryIDs.isEmpty)
    if targetIsGrouped {
      #expect(settings.repositoryGroups[1].repositoryIDs == Set(ids.map(\.rawValue)))
    }
    // A second move inside the same group must use the new target position.
    let membership = settings.repositoryGroups
    await store.send(.repositoryDropped([ids[0]], relativeTo: ids[1], after: false))
    #expect(store.state.orderedRepositoryIDs() == ids)
    #expect(settings.repositoryGroups == membership)
    await store.send(.repositoryDropped([ids[0]], relativeTo: ids[0], after: true))
    #expect(store.state.orderedRepositoryIDs() == ids)
    #expect(settings.repositoryGroups == membership)
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

  @Test(.dependencies) func sidebarCreationAsksForNameAndCancelKeepsMembership() async {
    @Shared(.settingsFile) var file
    let existingID = UUID()
    $file.withLock {
      $0.updateRepositoryGroups(.create(existingID, "Existing"))
      $0.updateRepositoryGroups(.assign("/tmp/repo", existingID))
    }
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.repositoryGroupCreation(.request("/tmp/repo")))
    #expect(store.state.repositoryGroupDraft == RepositoryGroupDraft(repositoryID: "/tmp/repo"))
    #expect(file.repositoryGroups.count == 1)
    await store.send(.repositoryGroupCreation(.nameChanged("  ")))
    await store.send(.repositoryGroupCreation(.confirm))
    #expect(store.state.repositoryGroupDraft != nil)
    #expect(file.repositoryGroups.count == 1)
    await store.send(.repositoryGroupCreation(.cancel))
    #expect(store.state.repositoryGroupDraft == nil)
    #expect(file.repositoryGroups[0].repositoryIDs == ["/tmp/repo"])
    await store.send(.repositoryGroupCreation(.request("/tmp/repo")))
    await store.send(.repositoryGroupCreation(.nameChanged("  My Work  ")))
    await store.send(.repositoryGroupCreation(.confirm))
    #expect(store.state.repositoryGroupDraft == nil)
    #expect(file.repositoryGroups.map(\.name) == ["Existing", "My Work"])
    #expect(file.repositoryGroups[0].repositoryIDs.isEmpty)
    #expect(file.repositoryGroups[1].repositoryIDs == ["/tmp/repo"])
  }

  @Test(.dependencies, arguments: [false, true])
  func settingsCreationOnlyPersistsAfterNamedConfirmation(includeRepository: Bool) async {
    @Shared(.settingsFile) var file
    let repositoryID: String? = includeRepository ? "/tmp/repo" : nil
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }
    await store.send(.repositoryGroupCreation(.request(repositoryID))) {
      $0.repositoryGroupDraft = RepositoryGroupDraft(repositoryID: repositoryID)
    }
    #expect(file.repositoryGroups.isEmpty)
    await store.send(.repositoryGroupCreation(.nameChanged(" \n "))) {
      $0.repositoryGroupDraft?.name = " \n "
    }
    await store.send(.repositoryGroupCreation(.confirm))
    #expect(file.repositoryGroups.isEmpty)
    await store.send(.repositoryGroupCreation(.cancel)) { $0.repositoryGroupDraft = nil }
    #expect(file.repositoryGroups.isEmpty)
    await store.send(.repositoryGroupCreation(.request(repositoryID))) {
      $0.repositoryGroupDraft = RepositoryGroupDraft(repositoryID: repositoryID)
    }
    await store.send(.repositoryGroupCreation(.nameChanged("  Personal  "))) {
      $0.repositoryGroupDraft?.name = "  Personal  "
    }
    await store.send(.repositoryGroupCreation(.confirm)) { $0.repositoryGroupDraft = nil }
    #expect(file.repositoryGroups.map(\.name) == ["Personal"])
    #expect(file.repositoryGroups[0].repositoryIDs == (includeRepository ? ["/tmp/repo"] : []))
  }

}
