import ComposableArchitecture
import ConcurrencyExtras
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

/// Remote `worktree.delete` and `worktrees.refresh` in the app: the
/// `AppFeature` bridge (`remoteWorktreeDeletions`), the branch-keeping and
/// second dirty check in `RepositoriesFeature`, and its load generations.
/// Every test uses its own repository path, so `@Shared` repository settings
/// (the delete script) never leak between tests.
@MainActor
struct AppFeatureRemoteWorktreeDeleteTests {
  private typealias Deletion = AppFeature.RemoteWorktreeDeletion
  private static let dirtyMessage =
    "the worktree has uncommitted changes, untracked or ignored files (1): .env; "
    + "commit, stash or remove them on the Mac first"

  // MARK: - AppFeature bridge

  @Test(.dependencies) func aCleanRequestDeletesKeepingTheBranchAndSettlesOnlyOnWorktreeDeleted() async {
    let fixture = Fixture()
    let removed = LockIsolated<[Bool]>([])
    let store = makeAppStore(fixture) {
      $0.gitClient.worktreeChanges = { _ in WorktreeDirtyState() }
      $0.gitClient.removeWorktree = { worktree, deleteBranch in
        removed.withValue { $0.append(deleteBranch) }
        return worktree.workingDirectory
      }
    }
    await store.send(.remoteWorktreeDeleteRequested(worktreeID: fixture.feature.id, repositoryID: fixture.repositoryID))
    #expect(store.state.remoteWorktreeDeletions[fixture.feature.id] == .checking(abandoned: false))
    await store.receive(\.remoteWorktreeDeleteChecked)
    // Its own `.checking` entry does not make it busy.
    await store.receive({ action in
      guard case .repositories(.deleteSidebarItemConfirmed(let id, let repositoryID, let background, let keepBranch)) =
        action
      else { return false }
      return id == fixture.feature.id && repositoryID == fixture.repositoryID && background && keepBranch
    })
    await store.finish(timeout: .seconds(30))
    await store.skipReceivedActions(strict: false)
    // The setting deletes branches by default; a remote delete never does.
    #expect(removed.value == [false])
    #expect(store.state.remoteWorktreeDeletions[fixture.feature.id] == .deleted)
    #expect(store.state.repositories.branchKeepingDeleteIDs.isEmpty)
  }

  @Test(.dependencies) func aDirtyWorktreeIsRefusedWithoutDeleting() async {
    let fixture = Fixture()
    let removed = LockIsolated(0)
    let store = makeAppStore(fixture) {
      $0.gitClient.worktreeChanges = { _ in WorktreeDirtyState(paths: [".env"]) }
      $0.gitClient.removeWorktree = { worktree, _ in
        removed.withValue { $0 += 1 }
        return worktree.workingDirectory
      }
    }
    await store.send(.remoteWorktreeDeleteRequested(worktreeID: fixture.feature.id, repositoryID: fixture.repositoryID))
    await store.finish(timeout: .seconds(30))
    await store.skipReceivedActions(strict: false)
    #expect(
      store.state.remoteWorktreeDeletions[fixture.feature.id]
        == .failed(code: "worktree_dirty", message: Self.dirtyMessage))
    #expect(removed.value == 0)
    #expect(store.state.repositories.alert == nil)
  }

  @Test(.dependencies) func aCheckErrorRefusesWithWorktreeFailed() async {
    let fixture = Fixture()
    let store = makeAppStore(fixture) {
      $0.gitClient.worktreeChanges = { _ in throw CheckError() }
    }
    await store.send(.remoteWorktreeDeleteRequested(worktreeID: fixture.feature.id, repositoryID: fixture.repositoryID))
    await store.finish(timeout: .seconds(30))
    await store.skipReceivedActions(strict: false)
    #expect(
      store.state.remoteWorktreeDeletions[fixture.feature.id]
        == .failed(code: "worktree_failed", message: "could not check the worktree for changes: boom"))
  }

  @Test(.dependencies) func anOrphanSkipsTheCheck() async {
    let fixture = Fixture(featureIsMissing: true)
    let checks = LockIsolated(0)
    let store = makeAppStore(fixture) {
      $0.gitClient.worktreeChanges = { _ in
        checks.withValue { $0 += 1 }
        return WorktreeDirtyState(paths: ["x"])
      }
      $0.gitClient.removeWorktree = { worktree, _ in worktree.workingDirectory }
    }
    await store.send(.remoteWorktreeDeleteRequested(worktreeID: fixture.feature.id, repositoryID: fixture.repositoryID))
    await store.finish(timeout: .seconds(30))
    await store.skipReceivedActions(strict: false)
    #expect(checks.value == 0)
    #expect(store.state.remoteWorktreeDeletions[fixture.feature.id] == .deleted)
  }

  /// `isMissing` is from the last load: a directory that came back is checked (Codex ZD10 r1 F2).
  @Test(.dependencies) func aMissingWorktreeWhoseDirectoryCameBackIsChecked() async throws {
    let fixture = Fixture(featureIsMissing: true)
    try FileManager.default.createDirectory(at: fixture.feature.workingDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: fixture.root)) }
    let dirty = WorktreeDirtyState(paths: ["notes.txt"])
    let checks = LockIsolated(0)
    let removed = LockIsolated(0)
    let store = makeAppStore(fixture) {
      $0.gitClient.worktreeChanges = { _ in
        checks.withValue { $0 += 1 }
        return dirty
      }
      $0.gitClient.removeWorktree = { worktree, _ in
        removed.withValue { $0 += 1 }
        return worktree.workingDirectory
      }
    }
    await store.send(.remoteWorktreeDeleteRequested(worktreeID: fixture.feature.id, repositoryID: fixture.repositoryID))
    await store.finish(timeout: .seconds(30))
    await store.skipReceivedActions(strict: false)
    #expect(checks.value == 1)
    #expect(removed.value == 0)
    #expect(
      store.state.remoteWorktreeDeletions[fixture.feature.id]
        == .failed(code: "worktree_dirty", message: dirty.message ?? ""))
  }

  @Test(.dependencies) func theReCheckRefusesARowThatBecameBusyDuringTheCheck() async {
    let fixture = Fixture()
    var repositories = fixture.repositoriesState()
    repositories.sidebarItems[id: fixture.feature.id]?.lifecycle = .archiving
    let store = makeAppStore(fixture, repositories: repositories, deletion: .checking(abandoned: false))
    await store.send(.remoteWorktreeDeleteChecked(worktreeID: fixture.feature.id, result: .clean))
    #expect(
      store.state.remoteWorktreeDeletions[fixture.feature.id]
        == .failed(code: "worktree_busy", message: "the worktree is busy (being created, archived or deleted)"))
    await store.finish(timeout: .seconds(30))
  }

  @Test(.dependencies) func aLateCheckResultForASettledEntryIsIgnored() async {
    let fixture = Fixture()
    let store = makeAppStore(fixture, deletion: .failed(code: "worktree_failed", message: "first"))
    await store.send(.remoteWorktreeDeleteChecked(worktreeID: fixture.feature.id, result: .clean))
    #expect(
      store.state.remoteWorktreeDeletions[fixture.feature.id] == .failed(code: "worktree_failed", message: "first"))
    await store.finish(timeout: .seconds(30))
  }

  @Test(.dependencies) func appFailuresSettleAsWorktreeFailed() async {
    let fixture = Fixture()
    let cases: [(RepositoriesFeature.Action, Deletion)] = [
      (
        .deleteWorktreeFailed("git boom", worktreeID: fixture.feature.id),
        .failed(code: "worktree_failed", message: "Unable to delete worktree: git boom")
      ),
      (
        .deleteScriptCompleted(worktreeID: fixture.feature.id, exitCode: 3, tabId: nil),
        .failed(code: "worktree_failed", message: "Delete script failed (exit code 3).")
      ),
      (
        .deleteScriptCompleted(worktreeID: fixture.feature.id, exitCode: nil, tabId: nil),
        .failed(code: "worktree_failed", message: "Delete cancelled.")
      ),
      (
        .deleteWorktreeAbortedDirty(worktreeID: fixture.feature.id, message: Self.dirtyMessage),
        .failed(code: "worktree_dirty", message: Self.dirtyMessage)
      ),
      (
        .deleteWorktreeApply(WorktreeID(fixture.root + "/gone"), fixture.repositoryID),
        .failed(code: "worktree_failed", message: "The worktree could not be found. It may have already been removed.")
      ),
    ]
    for (action, expected) in cases {
      var id = fixture.feature.id
      if case .deleteWorktreeApply(let applied, _) = action { id = applied }
      let store = makeAppStore(fixture, deletion: .deleting(abandoned: false), deletionID: id)
      await store.send(.repositories(action))
      #expect(store.state.remoteWorktreeDeletions[id] == expected)
      await store.finish(timeout: .seconds(30))
      await store.skipReceivedActions(strict: false)
    }
  }

  @Test(.dependencies) func aScriptSuccessWhoseWorktreeVanishedSettlesAsFailed() async {
    let fixture = Fixture()
    var repositories = fixture.repositoriesState()
    repositories.sidebarItems[id: fixture.feature.id]?.lifecycle = .deletingScript
    // The worktree left the roster while its script ran; the row is still there.
    repositories.repositories = [
      Repository(
        id: fixture.repositoryID, rootURL: URL(fileURLWithPath: fixture.root), name: "repo", worktrees: [fixture.main])
    ]
    let store = makeAppStore(fixture, repositories: repositories, deletion: .deleting(abandoned: false))
    await store.send(.repositories(.deleteScriptCompleted(worktreeID: fixture.feature.id, exitCode: 0, tabId: nil)))
    #expect(
      store.state.remoteWorktreeDeletions[fixture.feature.id]
        == .failed(
          code: "worktree_failed", message: "The delete script completed, but the worktree could not be found."))
    await store.finish(timeout: .seconds(30))
    await store.skipReceivedActions(strict: false)
  }

  @Test(.dependencies) func aWorktreeThatLeftTheRosterSettlesAsFailedButADeletedOneStays() async {
    let fixture = Fixture()
    let other = WorktreeID(fixture.root + "/other")
    var initial = AppFeature.State(repositories: fixture.repositoriesState(), settings: SettingsFeature.State())
    initial.remoteWorktreeDeletions[fixture.feature.id] = .checking(abandoned: false)
    initial.remoteWorktreeDeletions[other] = .deleted
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in }
    }
    store.exhaustivity = .off
    await store.send(.repositories(.delegate(.repositoriesChanged([]))))
    #expect(
      store.state.remoteWorktreeDeletions[fixture.feature.id]
        == .failed(code: "worktree_failed", message: Deletion.leftTheListMessage))
    #expect(store.state.remoteWorktreeDeletions[other] == .deleted)
    await store.finish(timeout: .seconds(30))
    await store.skipReceivedActions(strict: false)
  }

  @Test(.dependencies) func anAbandonedDeleteKeepsGuardingAndIsDroppedByItsOutcome() async {
    let fixture = Fixture()
    let store = makeAppStore(fixture, deletion: .deleting(abandoned: false))
    await store.send(.remoteWorktreeDeleteAbandoned(worktreeID: fixture.feature.id)) {
      $0.remoteWorktreeDeletions[fixture.feature.id] = .deleting(abandoned: true)
    }
    // The guard holds: `list` offers no delete and a retry is busy.
    #expect(
      RemoteWorktreeDeleteRejection.check(
        RemoteWorktreeDeleteFacts(
          isArchived: false, isGitRepository: true, isBeingRemoved: false, isMain: false,
          lifecycleIsIdle: true, inFlight: store.state.remoteWorktreeDeletions[fixture.feature.id] != nil)) == .busy)
    await store.send(.repositories(.deleteWorktreeFailed("boom", worktreeID: fixture.feature.id)))
    #expect(store.state.remoteWorktreeDeletions.isEmpty)
    await store.finish(timeout: .seconds(30))
    await store.skipReceivedActions(strict: false)
  }

  @Test(.dependencies) func consumingRemovesASettledEntry() async {
    let fixture = Fixture()
    let store = makeAppStore(fixture, deletion: .deleted)
    await store.send(.remoteWorktreeDeleteConsumed(worktreeID: fixture.feature.id)) {
      $0.remoteWorktreeDeletions[fixture.feature.id] = nil
    }
    await store.finish(timeout: .seconds(30))
  }

  // MARK: - RepositoriesFeature: branch and second check

  @Test(.dependencies) func aMacDeleteStillFollowsTheBranchSetting() async {
    let fixture = Fixture()
    let removed = LockIsolated<[Bool]>([])
    let store = makeRepositoriesStore(fixture) {
      $0.gitClient.removeWorktree = { worktree, deleteBranch in
        removed.withValue { $0.append(deleteBranch) }
        return worktree.workingDirectory
      }
    }
    await store.send(.deleteSidebarItemConfirmed(fixture.feature.id, fixture.repositoryID))
    await store.finish(timeout: .seconds(30))
    await store.skipReceivedActions(strict: false)
    #expect(removed.value == [true])
  }

  @Test(.dependencies) func keepBranchKeepsTheBranchAndRunsNoSecondCheckWithoutAScript() async {
    let fixture = Fixture()
    let removed = LockIsolated<[Bool]>([])
    let checks = LockIsolated(0)
    let store = makeRepositoriesStore(fixture) {
      $0.gitClient.removeWorktree = { worktree, deleteBranch in
        removed.withValue { $0.append(deleteBranch) }
        return worktree.workingDirectory
      }
      $0.gitClient.worktreeChanges = { _ in
        checks.withValue { $0 += 1 }
        return WorktreeDirtyState()
      }
    }
    await store.send(
      .deleteSidebarItemConfirmed(fixture.feature.id, fixture.repositoryID, background: true, keepBranch: true))
    await store.finish(timeout: .seconds(30))
    await store.skipReceivedActions(strict: false)
    #expect(removed.value == [false])
    #expect(checks.value == 0)
    #expect(store.state.branchKeepingDeleteIDs.isEmpty)
  }

  @Test(.dependencies) func aFileWrittenDuringTheDeleteScriptAbortsTheDelete() async {
    let fixture = Fixture()
    var state = fixture.repositoriesState()
    state.sidebarItems[id: fixture.feature.id]?.lifecycle = .deletingScript
    state.branchKeepingDeleteIDs.insert(fixture.feature.id)
    let removed = LockIsolated(0)
    let store = makeRepositoriesStore(fixture, state: state) {
      $0.gitClient.worktreeChanges = { _ in WorktreeDirtyState(paths: [".env"]) }
      $0.gitClient.removeWorktree = { worktree, _ in
        removed.withValue { $0 += 1 }
        return worktree.workingDirectory
      }
    }
    await store.send(.deleteScriptCompleted(worktreeID: fixture.feature.id, exitCode: 0, tabId: nil))
    await store.receive(\.deleteWorktreeApply)
    await store.receive(\.deleteWorktreeAbortedDirty)
    await store.finish(timeout: .seconds(30))
    await store.skipReceivedActions(strict: false)
    #expect(removed.value == 0)
    #expect(store.state.sidebarItems[id: fixture.feature.id]?.lifecycle == .idle)
    #expect(store.state.repositories[id: fixture.repositoryID]?.worktrees[id: fixture.feature.id] != nil)
    #expect(store.state.alert == nil)
    #expect(store.state.branchKeepingDeleteIDs.isEmpty)
    #expect(store.state.dirtyRecheckDeleteIDs.isEmpty)
  }

  @Test(.dependencies) func aFailingSecondCheckFailsTheDelete() async {
    let fixture = Fixture()
    var state = fixture.repositoriesState()
    state.sidebarItems[id: fixture.feature.id]?.lifecycle = .deletingScript
    state.branchKeepingDeleteIDs.insert(fixture.feature.id)
    let store = makeRepositoriesStore(fixture, state: state) {
      $0.gitClient.worktreeChanges = { _ in throw CheckError() }
    }
    await store.send(.deleteScriptCompleted(worktreeID: fixture.feature.id, exitCode: 0, tabId: nil))
    await store.receive(\.deleteWorktreeApply)
    await store.receive(\.deleteWorktreeFailed)
    await store.finish(timeout: .seconds(30))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.sidebarItems[id: fixture.feature.id]?.lifecycle == .idle)
    #expect(store.state.branchKeepingDeleteIDs.isEmpty)
  }

  @Test(.dependencies) func marksOfAWorktreeThatLeftTheRosterAreDropped() async {
    let fixture = Fixture()
    var state = fixture.repositoriesState()
    state.branchKeepingDeleteIDs = [fixture.feature.id]
    state.dirtyRecheckDeleteIDs = [fixture.feature.id]
    let store = makeRepositoriesStore(fixture, state: state)
    let remaining = Repository(
      id: fixture.repositoryID, rootURL: URL(fileURLWithPath: fixture.root), name: "repo", worktrees: [fixture.main])
    await store.send(
      .repositoriesLoaded([remaining], failures: [], roots: [URL(fileURLWithPath: fixture.root)], animated: false))
    #expect(store.state.branchKeepingDeleteIDs.isEmpty)
    #expect(store.state.dirtyRecheckDeleteIDs.isEmpty)
    await store.finish(timeout: .seconds(30))
    await store.skipReceivedActions(strict: false)
  }

  /// A row still running its delete keeps the marks while its worktree is out of
  /// the roster, so a worktree back at that path is still re-checked and keeps its
  /// branch (Codex ZD10 r1 F3).
  @Test(.dependencies) func marksOfARowStillDeletingSurviveLeavingTheRoster() async {
    let fixture = Fixture()
    var state = fixture.repositoriesState()
    state.sidebarItems[id: fixture.feature.id]?.lifecycle = .deletingScript
    state.branchKeepingDeleteIDs = [fixture.feature.id]
    state.dirtyRecheckDeleteIDs = [fixture.feature.id]
    let store = makeRepositoriesStore(fixture, state: state)
    let remaining = Repository(
      id: fixture.repositoryID, rootURL: URL(fileURLWithPath: fixture.root), name: "repo", worktrees: [fixture.main])
    await store.send(
      .repositoriesLoaded([remaining], failures: [], roots: [URL(fileURLWithPath: fixture.root)], animated: false))
    #expect(store.state.sidebarItems[id: fixture.feature.id]?.lifecycle == .deletingScript)
    #expect(store.state.branchKeepingDeleteIDs == [fixture.feature.id])
    #expect(store.state.dirtyRecheckDeleteIDs == [fixture.feature.id])
    await store.finish(timeout: .seconds(30))
    await store.skipReceivedActions(strict: false)
  }

  // MARK: - RepositoriesFeature: load generations

  @Test(.dependencies) func aReloadCompletesItsGenerationOnlyWhenItsResultLands() async {
    let fixture = Fixture()
    let worktrees = [fixture.main, fixture.feature]
    let store = makeRepositoriesStore(fixture) {
      $0.gitClient.worktrees = { _ in worktrees }
    }
    await store.send(.reloadRepositories(animated: false))
    #expect(store.state.loadGeneration.started == 1)
    await store.finish(timeout: .seconds(30))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.loadGeneration.completed == 1)
  }

  @Test(.dependencies) func anInMemoryRosterUpdateCompletesNoGeneration() async {
    let fixture = Fixture()
    var state = fixture.repositoriesState()
    state.loadGeneration.started = 1
    let roster = state.repositories.map { $0 }
    let store = makeRepositoriesStore(fixture, state: state)
    // `.repositoriesLoaded` without a git load (e.g. a repository removed in memory).
    await store.send(
      .repositoriesLoaded(roster, failures: [], roots: [URL(fileURLWithPath: fixture.root)], animated: false))
    #expect(store.state.loadGeneration.completed == 0)
    await store.finish(timeout: .seconds(30))
    await store.skipReceivedActions(strict: false)
  }

  @Test func aGenerationCompletesAtMostOnceAndNeverGoesBack() {
    var generation = RepositoriesFeature.LoadGeneration()
    let first = generation.begin()
    let second = generation.begin()
    generation.finish(nil)
    #expect(generation.completed == 0)
    generation.finish(second)
    generation.finish(first)
    #expect(generation.started == 2)
    #expect(generation.completed == 2)
  }

  @Test(.dependencies) func loadPersistedClearsTheFlagBeforeItsLoadCompletes() async {
    let fixture = Fixture()
    var state = fixture.repositoriesState()
    state.isRefreshingWorktrees = true
    let store = makeRepositoriesStore(fixture, state: state)
    await store.send(.loadPersistedRepositories)
    #expect(!store.state.isRefreshingWorktrees)
    #expect(store.state.loadGeneration.started == 1)
    #expect(store.state.loadGeneration.completed == 0)
    await store.finish(timeout: .seconds(30))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.loadGeneration.completed == 1)
  }

  @Test(.dependencies) func nothingToLoadCompletesAtOnce() async {
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off
    await store.send(.reloadRepositories(animated: false))
    #expect(store.state.loadGeneration.started == 1)
    #expect(store.state.loadGeneration.completed == 1)
  }

  // MARK: - Helpers

  private nonisolated struct CheckError: LocalizedError {
    var errorDescription: String? { "boom" }
  }

  /// A git repository at a unique path with its main worktree and `feature`.
  private struct Fixture {
    let root = "/tmp/remote-delete-\(UUID().uuidString)"
    let main: Worktree
    let feature: Worktree

    init(featureIsMissing: Bool = false) {
      let rootURL = URL(fileURLWithPath: root)
      main = Worktree(
        id: WorktreeID(root), name: "main", detail: "detail", workingDirectory: rootURL, repositoryRootURL: rootURL)
      feature = Worktree(
        id: WorktreeID(root + "/feature"), name: "feature", detail: "detail",
        workingDirectory: URL(fileURLWithPath: root + "/feature"), repositoryRootURL: rootURL,
        isMissing: featureIsMissing)
    }

    var repositoryID: Repository.ID { Repository.ID(root) }

    func repositoriesState() -> RepositoriesFeature.State {
      var state = RepositoriesFeature.State()
      state.repositories = [
        Repository(
          id: repositoryID, rootURL: URL(fileURLWithPath: root), name: "repo", worktrees: [main, feature])
      ]
      state.repositoryRoots = [URL(fileURLWithPath: root)]
      state.selection = .worktree(main.id)
      state.isInitialLoadComplete = true
      state.reconcileSidebarForTesting()
      return state
    }
  }

  private func makeAppStore(
    _ fixture: Fixture,
    repositories: RepositoriesFeature.State? = nil,
    deletion: Deletion? = nil,
    deletionID: Worktree.ID? = nil,
    _ extraDependencies: @escaping (inout DependencyValues) -> Void = { _ in }
  ) -> TestStoreOf<AppFeature> {
    var initial = AppFeature.State(
      repositories: repositories ?? fixture.repositoriesState(), settings: SettingsFeature.State())
    if let deletion { initial.remoteWorktreeDeletions[deletionID ?? fixture.feature.id] = deletion }
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in }
      let main = fixture.main
      $0.gitClient.worktrees = { _ in [main] }
      extraDependencies(&$0)
    }
    store.exhaustivity = .off
    return store
  }

  private func makeRepositoriesStore(
    _ fixture: Fixture,
    state: RepositoriesFeature.State? = nil,
    _ extraDependencies: @escaping (inout DependencyValues) -> Void = { _ in }
  ) -> TestStoreOf<RepositoriesFeature> {
    let store = TestStore(initialState: state ?? fixture.repositoriesState()) {
      RepositoriesFeature()
    } withDependencies: {
      let main = fixture.main
      $0.gitClient.worktrees = { _ in [main] }
      $0.gitClient.removeWorktree = { worktree, _ in worktree.workingDirectory }
      extraDependencies(&$0)
    }
    store.exhaustivity = .off
    return store
  }
}
