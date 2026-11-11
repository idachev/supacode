import Clocks
import ComposableArchitecture
import ConcurrencyExtras
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

/// The `worktree.delete` and `worktrees.refresh` rules that need no live app
/// store: the shared delete rule, the bounded waits and the reply frames.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RemoteAccessWorktreeDeleteTests {
  typealias Deletion = AppFeature.RemoteWorktreeDeletion
  private nonisolated static let worktreeID = WorktreeID("/tmp/repo/feature-x")
  private nonisolated static let start = RemoteWorktreeDeleteStart(
    worktreeID: WorktreeID("/tmp/repo/feature-x"), repositoryID: RepositoryID("/tmp/repo"))

  // MARK: - Shared rule

  private static func check(
    found: Bool = true, isArchived: Bool = false, isGitRepository: Bool = true, isBeingRemoved: Bool = false,
    isMain: Bool = false, lifecycleIsIdle: Bool = true, inFlight: Bool = false
  ) -> RemoteWorktreeDeleteRejection? {
    RemoteWorktreeDeleteRejection.check(
      found
        ? RemoteWorktreeDeleteFacts(
          isArchived: isArchived, isGitRepository: isGitRepository, isBeingRemoved: isBeingRemoved,
          isMain: isMain, lifecycleIsIdle: lifecycleIsIdle, inFlight: inFlight)
        : nil)
  }

  @Test func everyRejectionHasItsCodeAndMessage() {
    #expect(Self.check() == nil)
    #expect(Self.check(found: false) == .unknownWorktree)
    #expect(Self.check(isArchived: true) == .unknownWorktree)
    #expect(Self.check(isGitRepository: false) == .folder)
    #expect(Self.check(isMain: true) == .mainWorktree)
    #expect(Self.check(isBeingRemoved: true) == .repositoryBeingRemoved)
    #expect(Self.check(lifecycleIsIdle: false) == .busy)
    #expect(Self.check(inFlight: true) == .busy)
    struct Expected {
      let rejection: RemoteWorktreeDeleteRejection
      let code: String
      let message: String
    }
    let expected: [Expected] = [
      Expected(rejection: .missingWorktree, code: "worktree_invalid", message: "worktree.delete needs a worktreeId"),
      Expected(rejection: .unknownWorktree, code: "worktree_invalid", message: "no such worktree"),
      Expected(
        rejection: .folder, code: "worktree_unsupported", message: "folders cannot be deleted from the remote"),
      Expected(
        rejection: .mainWorktree, code: "worktree_unsupported", message: "the main worktree cannot be deleted"),
      Expected(
        rejection: .repositoryBeingRemoved, code: "worktree_unsupported",
        message: "the repository is being removed"),
      Expected(
        rejection: .busy, code: "worktree_busy",
        message: "the worktree is busy (being created, archived or deleted)"),
    ]
    for entry in expected {
      #expect(entry.rejection.code == entry.code)
      #expect(entry.rejection.message == entry.message)
    }
  }

  @Test(.dependencies) func theStateRuleRefusesPendingMainBusyAndInFlight() {
    let main = Self.worktree("/tmp/repo")
    let feature = Self.worktree("/tmp/repo/feature-x")
    var state = RepositoriesFeature.State()
    state.repositories = [
      Repository(id: "/tmp/repo", rootURL: URL(fileURLWithPath: "/tmp/repo"), name: "repo", worktrees: [main, feature])
    ]
    #expect(
      RemoteWorktreeDeleteRejection.check(worktreeID: feature.id.rawValue, in: state, inFlight: false)
        == .success(Self.start))
    #expect(
      RemoteWorktreeDeleteRejection.check(worktreeID: feature.id.rawValue, in: state, inFlight: true)
        == .failure(.busy))
    #expect(
      RemoteWorktreeDeleteRejection.check(worktreeID: main.id.rawValue, in: state, inFlight: false)
        == .failure(.mainWorktree))
    #expect(
      RemoteWorktreeDeleteRejection.check(worktreeID: "pending:remote-1", in: state, inFlight: false)
        == .failure(.unknownWorktree))
    state.seedRemovalBatch(pending: ["/tmp/repo": .gitRepositoryUnlink])
    #expect(
      RemoteWorktreeDeleteRejection.check(worktreeID: feature.id.rawValue, in: state, inFlight: false)
        == .failure(.repositoryBeingRemoved))
  }

  @Test func listCarriesCanDeleteWorktreeFromTheSharedRule() throws {
    let repositories = RemoteSnapshotBuilder.build(repositories: [
      .init(
        id: "/r", name: "r",
        worktrees: [
          .init(
            id: "/r", name: "main", branch: "main", status: .main, focused: false, title: nil, sidebarIndex: 0,
            tabs: [], canDeleteWorktree: Self.check(isMain: true) == nil),
          .init(
            id: "/r/x", name: "x", branch: "x", status: .unpinned, focused: false, title: nil, sidebarIndex: 0,
            tabs: [], canDeleteWorktree: Self.check() == nil),
        ])
    ])
    #expect(repositories[0].worktrees.map(\.canDeleteWorktree) == [false, true])
    let json = try Self.json(RemoteListMessage(id: 1, repos: repositories))
    let worktrees = try #require((json["repos"] as? [[String: Any]])?.first?["worktrees"] as? [[String: Any]])
    #expect(worktrees.map { $0["canDeleteWorktree"] as? Bool } == [false, true])
  }

  // MARK: - list frame

  @Test func listWithoutAnIDEncodesAnExplicitNullAndCanRefresh() throws {
    let data = RemoteJSON.encode(RemoteListMessage(id: nil, repos: []))
    let text = try #require(String(bytes: data, encoding: .utf8))
    #expect(text.contains(#""id":null"#))
    let json = try Self.json(RemoteListMessage(id: nil, repos: []))
    #expect(json["canRefreshWorktrees"] as? Bool == true)
    #expect(json["loadFailures"] == nil)
    #expect(json["sections"] is [Any])
  }

  @Test func listCarriesLoadFailuresSortedByRepository() throws {
    let failures = RemoteSnapshotSource.loadFailures(["/b": "not a git repository", "/a": "permission denied"])
    #expect(
      failures == [
        RemoteLoadFailure(repositoryId: "/a", message: "permission denied"),
        RemoteLoadFailure(repositoryId: "/b", message: "not a git repository"),
      ])
    let json = try Self.json(RemoteListMessage(id: 9, repos: [], loadFailures: failures))
    let encoded = try #require(json["loadFailures"] as? [[String: String]])
    #expect(encoded.first == ["repositoryId": "/a", "message": "permission denied"])
  }

  // MARK: - Delete wait

  /// Test doubles for what the wait reads from and tells the app.
  private final class Probes: Sendable {
    let deletion = LockIsolated<Deletion?>(.checking(abandoned: false))
    let consumed = LockIsolated(0)
    let abandoned = LockIsolated(0)

    nonisolated deinit {}
  }

  private func start(_ probes: Probes, clock: TestClock<Duration>) -> Task<RemoteWorktreeDeleteOutcome, Never> {
    Task { @MainActor in
      await RemoteHostRouter.awaitWorktreeDelete(
        clock: clock,
        deletion: { probes.deletion.value },
        consume: {
          probes.consumed.withValue { $0 += 1 }
          probes.deletion.setValue(nil)
        },
        abandon: {
          probes.abandoned.withValue { $0 += 1 }
          var deletions: [WorktreeID: Deletion] = [:]
          deletions[Self.worktreeID] = probes.deletion.value
          Deletion.abandon(Self.worktreeID, in: &deletions)
          let updated = deletions[Self.worktreeID]
          probes.deletion.setValue(updated)
        })
    }
  }

  @Test func onlyTheDeletedEntryIsASuccess() async {
    let clock = TestClock()
    let probes = Probes()
    let wait = start(probes, clock: clock)
    await Task.megaYield()
    probes.deletion.setValue(.deleting(abandoned: false))
    await clock.advance(by: .milliseconds(100))
    await Task.megaYield()
    probes.deletion.setValue(.deleted)
    await clock.advance(by: .milliseconds(100))
    let outcome = await wait.value
    #expect(outcome == .deleted)
    #expect(probes.consumed.value == 1)
    #expect(
      RemoteHostRouter.worktreeDeleteReply(for: outcome, start: Self.start, requestID: 8)
        == .deleted(RemoteWorktreeDeleteMessage(id: 8, worktreeId: "/tmp/repo/feature-x", repositoryId: "/tmp/repo")))
  }

  @Test func aFailedEntryIsAnsweredWithItsCode() async {
    let clock = TestClock()
    let probes = Probes()
    let message = "the worktree has uncommitted changes, untracked or ignored files (1): .env; "
      + "commit, stash or remove them on the Mac first"
    probes.deletion.setValue(.failed(code: "worktree_dirty", message: message))
    let wait = start(probes, clock: clock)
    let outcome = await wait.value
    #expect(outcome == .failed(code: "worktree_dirty", message: message))
    #expect(probes.consumed.value == 1)
    #expect(
      RemoteHostRouter.worktreeDeleteReply(for: outcome, start: Self.start, requestID: nil)
        == .error(RemoteErrorMessage(id: nil, message: message, code: "worktree_dirty")))
  }

  @Test func noOutcomeInTimeTimesOutAndKeepsTheBusyGuard() async {
    let clock = TestClock()
    let probes = Probes()
    probes.deletion.setValue(.deleting(abandoned: false))
    let wait = start(probes, clock: clock)
    await Task.megaYield()
    await clock.advance(by: .seconds(300))
    let outcome = await wait.value
    #expect(outcome == .timedOut)
    #expect(RemoteHostRouter.worktreeDeleteTimeout == .seconds(300))
    #expect(probes.consumed.value == 0)
    #expect(probes.abandoned.value == 1)
    #expect(probes.deletion.value == .deleting(abandoned: true))
    #expect(
      RemoteHostRouter.worktreeDeleteReply(for: outcome, start: Self.start, requestID: 8)
        == .error(
          RemoteErrorMessage(
            id: 8, message: "the delete is still running on the Mac; the worktree may disappear from the list later",
            code: "worktree_timeout")))
  }

  @Test func aCancelledWaitAbandonsTheRunningDeleteAndSendsNothing() async {
    let clock = TestClock()
    let probes = Probes()
    let wait = start(probes, clock: clock)
    await Task.megaYield()
    wait.cancel()
    let outcome = await wait.value
    #expect(outcome == .cancelled)
    #expect(probes.abandoned.value == 1)
    #expect(probes.deletion.value == .checking(abandoned: true))
    #expect(RemoteHostRouter.worktreeDeleteReply(for: outcome, start: Self.start, requestID: 8) == nil)
  }

  @Test func anAbandonedEntryIsDroppedByItsOutcome() {
    var deletions: [WorktreeID: Deletion] = [Self.worktreeID: .deleting(abandoned: true)]
    Deletion.settleDeleting(Self.worktreeID, as: .deleted, in: &deletions)
    #expect(deletions.isEmpty)
    deletions[Self.worktreeID] = .checking(abandoned: false)
    // `settleDeleting` (the outcome arms) moves only a `.deleting` entry.
    Deletion.settleDeleting(Self.worktreeID, as: .deleted, in: &deletions)
    #expect(deletions[Self.worktreeID] == .checking(abandoned: false))
    Deletion.settleUnsettled(Self.worktreeID, as: .failed(code: "worktree_failed", message: "x"), in: &deletions)
    #expect(deletions[Self.worktreeID] == .failed(code: "worktree_failed", message: "x"))
    // A settled entry is never overwritten.
    Deletion.settleUnsettled(Self.worktreeID, as: .deleted, in: &deletions)
    #expect(deletions[Self.worktreeID] == .failed(code: "worktree_failed", message: "x"))
  }

  // MARK: - Refresh wait

  @Test func aRefreshAnswersOnlyAfterANewerGeneration() async {
    let clock = TestClock()
    let completed = LockIsolated(3)
    let wait = Task { @MainActor in
      await RemoteHostRouter.runWorktreesRefresh(after: 3, clock: clock, completed: { completed.value })
    }
    await Task.megaYield()
    await clock.advance(by: .milliseconds(500))
    completed.setValue(4)
    await clock.advance(by: .milliseconds(100))
    #expect(await wait.value == .loaded)
  }

  @Test func aRefreshWithoutANewerLoadTimesOut() async {
    let clock = TestClock()
    let wait = Task { @MainActor in
      await RemoteHostRouter.runWorktreesRefresh(after: 3, clock: clock, completed: { 3 })
    }
    await Task.megaYield()
    await clock.advance(by: .seconds(60))
    #expect(await wait.value == .timedOut)
    #expect(RemoteHostRouter.worktreesRefreshTimeout == .seconds(60))
    #expect(
      RemoteHostRouter.worktreesRefreshTimeoutError(requestID: 9)
        == RemoteErrorMessage(
          id: 9, message: "the refresh is still running on the Mac; send list again later", code: "refresh_timeout"))
  }

  // MARK: - Helpers

  private static func worktree(_ path: String) -> Worktree {
    Worktree(
      id: WorktreeID(path), name: URL(fileURLWithPath: path).lastPathComponent, detail: "detail",
      workingDirectory: URL(fileURLWithPath: path), repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"))
  }

  private static func json(_ message: RemoteListMessage) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: RemoteJSON.encode(message)) as? [String: Any])
  }
}
