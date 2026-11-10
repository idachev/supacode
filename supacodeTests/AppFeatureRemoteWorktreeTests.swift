import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

/// Remote `worktree.new` bookkeeping in `AppFeature`: the request arm and how
/// the existing creation outcome arms move `remoteWorktreeCreations` entries.
@MainActor
struct AppFeatureRemoteWorktreeTests {
  private static let cancelled = "Worktree creation was cancelled on the Mac."
  private let pendingID = WorktreeID("pending:remote-1")
  private let created = Worktree(
    id: WorktreeID("/tmp/repo/feature-x"),
    name: "feature-x",
    detail: "detail",
    workingDirectory: URL(fileURLWithPath: "/tmp/repo/feature-x"),
    repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
  )

  // MARK: - Request

  @Test(.dependencies) func aRequestCreatesWithTheExplicitNameAndFilesTheOutcome() async {
    let store = makeStore()
    let pendingID = self.pendingID
    await store.send(
      .remoteWorktreeNewRequested(repositoryID: "/tmp/missing", name: "feature-x", pendingID: pendingID)
    ) {
      $0.remoteWorktreeCreations[pendingID] = .creating(name: "feature-x")
    }
    await store.receive({ action in
      guard
        case .repositories(
          .createWorktreeInRepository(
            let repositoryID, let nameSource, let baseRefSource, _, _, _, let actionPendingID, let background, let pin,
            let permit)) = action,
        case .explicit("feature-x") = nameSource,
        case .repositorySetting = baseRefSource
      else { return false }
      return repositoryID == "/tmp/missing" && actionPendingID == pendingID && !background && !pin && permit == nil
    })
    // The real guard rejects the unknown repository; the rejection lands on the entry.
    await store.finish(timeout: .seconds(30))
    await store.skipReceivedActions(strict: false)
    #expect(
      store.state.remoteWorktreeCreations[pendingID]
        == .failed(message: "Unable to resolve a repository for the new worktree."))
  }

  // MARK: - Outcomes

  @Test(.dependencies) func aLocalSuccessRecordsTheWorktreeAndATabFailureMarksIt() async {
    let store = makeStore(creating: true)
    await store.send(
      .repositories(.createRandomWorktreeSucceeded(created, repositoryID: "/tmp/repo", pendingID: pendingID)))
    #expect(
      store.state.remoteWorktreeCreations[pendingID] == .created(worktreeID: created.id, name: "feature-x"))
    await store.send(.terminalEvent(.initialTabCreationFailed(worktreeID: created.id, message: "boom")))
    #expect(
      store.state.remoteWorktreeCreations[pendingID] == .tabFailed(worktreeID: created.id, name: "feature-x"))
    await store.finish(timeout: .seconds(30))
  }

  @Test(.dependencies) func anSSHSuccessRecordsTheRequestedName() async {
    let store = makeStore(creating: true)
    let remoteID = WorktreeID("devbox:/home/me/repo/feature-x")
    await store.send(.repositories(.remoteWorktreeCreationCompleted(pendingID: pendingID, worktreeID: remoteID)))
    #expect(store.state.remoteWorktreeCreations[pendingID] == .created(worktreeID: remoteID, name: "feature-x"))
    await store.finish(timeout: .seconds(30))
  }

  @Test(.dependencies) func aNameFailureCarriesTitleAndMessage() async {
    let store = makeStore(creating: true)
    await store.send(
      .repositories(
        .createRandomWorktreeFailed(
          title: "Branch name already exists", message: "Choose a different branch name and try again.",
          pendingID: pendingID, previousSelection: nil, repositoryID: "/tmp/repo", name: nil,
          baseDirectory: URL(fileURLWithPath: "/tmp/repo"))))
    #expect(
      store.state.remoteWorktreeCreations[pendingID]
        == .failed(message: "Branch name already exists: Choose a different branch name and try again."))
    await store.finish(timeout: .seconds(30))
  }

  @Test(.dependencies) func aRejectionCarriesTheBareMessage() async {
    let store = makeStore(creating: true)
    await store.send(
      .repositories(
        .worktreeCreationRejected(
          pendingID: pendingID, message: "Worktrees are only supported for git repositories.",
          licenseRequired: false)))
    #expect(
      store.state.remoteWorktreeCreations[pendingID]
        == .failed(message: "Worktrees are only supported for git repositories."))
    await store.finish(timeout: .seconds(30))
  }

  @Test(.dependencies) func aMacCancelFailsTheEntryEvenWhenGitSucceeds() async {
    let store = makeStore(creating: true, pendingRow: true) {
      $0.gitClient.removeWorktree = { worktree, _ in worktree.workingDirectory }
    }
    await store.send(.repositories(.cancelPendingWorktree(pendingID)))
    await store.receive(\.repositories.cliWorktreeAckCancelled)
    #expect(store.state.remoteWorktreeCreations[pendingID] == .failed(message: Self.cancelled))
    await store.send(
      .repositories(.createRandomWorktreeSucceeded(created, repositoryID: "/tmp/repo", pendingID: pendingID)))
    #expect(store.state.remoteWorktreeCreations[pendingID] == .failed(message: Self.cancelled))
    await store.finish(timeout: .seconds(30))
    await store.skipReceivedActions(strict: false)
  }

  @Test(.dependencies) func aSuccessAfterACancelFlagIsACancel() async {
    // The backstop: the cancel flag is set but the ack-cancel arm has not run.
    var repositories = makeRepositoriesState()
    repositories.cancelRequestedPendingIDs.insert(pendingID)
    let store = makeStore(repositories: repositories, creating: true) {
      $0.gitClient.removeWorktree = { worktree, _ in worktree.workingDirectory }
    }
    await store.send(
      .repositories(.createRandomWorktreeSucceeded(created, repositoryID: "/tmp/repo", pendingID: pendingID)))
    #expect(store.state.remoteWorktreeCreations[pendingID] == .failed(message: Self.cancelled))
    await store.finish(timeout: .seconds(30))
    await store.skipReceivedActions(strict: false)
  }

  @Test(.dependencies) func outcomesForUnknownPendingIDsAreIgnored() async {
    let store = makeStore()
    await store.send(
      .repositories(.createRandomWorktreeSucceeded(created, repositoryID: "/tmp/repo", pendingID: pendingID)))
    await store.send(
      .repositories(.worktreeCreationRejected(pendingID: pendingID, message: "boom", licenseRequired: false)))
    await store.send(.terminalEvent(.initialTabCreationFailed(worktreeID: created.id, message: "boom")))
    #expect(store.state.remoteWorktreeCreations.isEmpty)
    await store.finish(timeout: .seconds(30))
  }

  @Test(.dependencies) func aSettledEntryIsNeverOverwritten() async {
    let store = makeStore(creating: true)
    await store.send(
      .repositories(.worktreeCreationRejected(pendingID: pendingID, message: "first", licenseRequired: false)))
    await store.send(.repositories(.remoteWorktreeCreationCompleted(pendingID: pendingID, worktreeID: created.id)))
    await store.send(
      .repositories(.worktreeCreationRejected(pendingID: pendingID, message: "second", licenseRequired: false)))
    #expect(store.state.remoteWorktreeCreations[pendingID] == .failed(message: "first"))
    await store.finish(timeout: .seconds(30))
  }

  @Test(.dependencies) func consumingRemovesTheEntryAndLaterOutcomesAreIgnored() async {
    let store = makeStore(creating: true)
    await store.send(.remoteWorktreeCreationConsumed(pendingID: pendingID)) {
      $0.remoteWorktreeCreations[pendingID] = nil
    }
    await store.send(.repositories(.remoteWorktreeCreationCompleted(pendingID: pendingID, worktreeID: created.id)))
    #expect(store.state.remoteWorktreeCreations.isEmpty)
    await store.finish(timeout: .seconds(30))
  }

  // MARK: - Helpers

  private func makeRepositoriesState() -> RepositoriesFeature.State {
    let worktree = Worktree(
      id: WorktreeID("/tmp/repo/wt-1"),
      name: "wt-1",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
    )
    let repository = Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "repo",
      worktrees: [worktree],
    )
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    repositoriesState.isInitialLoadComplete = true
    return repositoriesState
  }

  private func makeStore(
    repositories: RepositoriesFeature.State? = nil,
    creating: Bool = false,
    pendingRow: Bool = false,
    _ extraDependencies: @escaping (inout DependencyValues) -> Void = { _ in }
  ) -> TestStoreOf<AppFeature> {
    var repositoriesState = repositories ?? makeRepositoriesState()
    if pendingRow {
      repositoriesState.pendingWorktrees = [
        PendingWorktree(
          id: pendingID,
          repositoryID: "/tmp/repo",
          progress: WorktreeCreationProgress(stage: .creatingWorktree, worktreeName: "feature-x")
        )
      ]
    }
    var initial = AppFeature.State(repositories: repositoriesState, settings: SettingsFeature.State())
    if creating { initial.remoteWorktreeCreations[pendingID] = .creating(name: "feature-x") }
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in }
      extraDependencies(&$0)
    }
    store.exhaustivity = .off
    return store
  }
}
