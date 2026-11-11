import Foundation
import IdentifiedCollections

/// The `code` values of the `error` frames a `worktree.delete` or a
/// `worktrees.refresh` can get (`docs/remote-access-protocol.md`).
nonisolated enum RemoteWorktreeDeleteErrorCode {
  static let invalid = RemoteWorktreeNewErrorCode.invalid
  static let unsupported = RemoteWorktreeNewErrorCode.unsupported
  static let busy = RemoteWorktreeNewErrorCode.busy
  static let failed = RemoteWorktreeNewErrorCode.failed
  static let timeout = RemoteWorktreeNewErrorCode.timeout
  static let dirty = "worktree_dirty"
  static let refreshTimeout = "refresh_timeout"
}

/// Why a `worktree.delete` is refused by the host before the app deletes
/// anything; the client gets `message` with `code`, and the Mac shows no alert.
nonisolated enum RemoteWorktreeDeleteRejection: Error, Equatable, Sendable {
  case missingWorktree
  case unknownWorktree
  case folder
  case mainWorktree
  case repositoryBeingRemoved
  case busy

  var code: String {
    switch self {
    case .missingWorktree, .unknownWorktree: RemoteWorktreeDeleteErrorCode.invalid
    case .folder, .mainWorktree, .repositoryBeingRemoved: RemoteWorktreeDeleteErrorCode.unsupported
    case .busy: RemoteWorktreeDeleteErrorCode.busy
    }
  }

  var message: String {
    switch self {
    case .missingWorktree: "worktree.delete needs a worktreeId"
    case .unknownWorktree: "no such worktree"
    case .folder: "folders cannot be deleted from the remote"
    case .mainWorktree: "the main worktree cannot be deleted"
    case .repositoryBeingRemoved: "the repository is being removed"
    case .busy: "the worktree is busy (being created, archived or deleted)"
    }
  }

  /// The one rule the request, the re-check after the dirty check and `list`'s
  /// `canDeleteWorktree` share, so `list` never offers what the host refuses.
  /// Nil when the worktree may be deleted. `facts` is nil when no repository
  /// lists the worktree. An archived worktree is not in `list`, so it is
  /// unknown here (ОВ12).
  static func check(_ facts: RemoteWorktreeDeleteFacts?) -> Self? {
    guard let facts, !facts.isArchived else { return .unknownWorktree }
    guard facts.isGitRepository else { return .folder }
    if facts.isMain { return .mainWorktree }
    if facts.isBeingRemoved { return .repositoryBeingRemoved }
    if !facts.lifecycleIsIdle || facts.inFlight { return .busy }
    return nil
  }
}

/// What `RemoteWorktreeDeleteRejection.check` decides on, for one worktree
/// that a repository lists.
nonisolated struct RemoteWorktreeDeleteFacts: Equatable, Sendable {
  let isArchived: Bool
  let isGitRepository: Bool
  let isBeingRemoved: Bool
  let isMain: Bool
  let lifecycleIsIdle: Bool
  /// Another remote delete of this worktree is in flight.
  let inFlight: Bool
}

// Main actor: it reads `RepositoriesFeature.State`, which is main-actor isolated.
@MainActor
extension RemoteWorktreeDeleteFacts {
  /// Reads the archived status, main-ness, removal and row lifecycle the way
  /// the Mac's own delete request does (`requestDeleteSidebarItems`).
  init(worktree: Worktree, repository: Repository, in state: RepositoriesFeature.State, inFlight: Bool) {
    let isMain = state.isMainWorktree(worktree)
    self.init(
      isArchived: state.sidebar.status(of: worktree.id, in: repository.id, isMain: isMain).isArchived,
      isGitRepository: repository.isGitRepository,
      isBeingRemoved: state.removingRepositoryIDs[repository.id] != nil,
      isMain: isMain,
      lifecycleIsIdle: (state.sidebarItems[id: worktree.id]?.lifecycle ?? .idle) == .idle,
      inFlight: inFlight)
  }
}

// Main actor: it reads `RepositoriesFeature.State`, which is main-actor isolated.
@MainActor
extension RemoteWorktreeDeleteRejection {
  /// `check` for a worktree that `repository` lists; `list` uses it for
  /// `canDeleteWorktree`.
  static func check(
    worktree: Worktree, repository: Repository, in state: RepositoriesFeature.State, inFlight: Bool
  ) -> Self? {
    check(RemoteWorktreeDeleteFacts(worktree: worktree, repository: repository, in: state, inFlight: inFlight))
  }

  /// `check` against the app's repositories state: finds the repository that
  /// lists `worktreeID` (a pending `pending:…` row is in none).
  static func check(
    worktreeID raw: String, in state: RepositoriesFeature.State, inFlight: Bool
  ) -> Result<RemoteWorktreeDeleteStart, Self> {
    for repository in state.repositories {
      guard let worktree = repository.worktrees.first(where: { $0.id.rawValue == raw }) else { continue }
      if let rejection = check(worktree: worktree, repository: repository, in: state, inFlight: inFlight) {
        return .failure(rejection)
      }
      return .success(RemoteWorktreeDeleteStart(worktreeID: worktree.id, repositoryID: repository.id))
    }
    return .failure(.unknownWorktree)
  }
}

/// A delete the app accepted: the worktree and its repository (for the reply).
nonisolated struct RemoteWorktreeDeleteStart: Equatable, Sendable {
  let worktreeID: Worktree.ID
  let repositoryID: Repository.ID
}

/// How a `worktree.delete` wait ended (`RemoteHostRouter.runWorktreeDelete`).
nonisolated enum RemoteWorktreeDeleteOutcome: Equatable, Sendable {
  /// The app reported the worktree deleted (`.worktreeDeleted`).
  case deleted
  /// The check or the app refused or failed, with the error `code` and `message`.
  case failed(code: String, message: String)
  /// No outcome within `worktreeDeleteTimeout`.
  case timedOut
  /// The phone's connection ended; nobody is answered.
  case cancelled
}

/// How a `worktrees.refresh` wait ended (`RemoteHostRouter.runWorktreesRefresh`).
nonisolated enum RemoteWorktreesRefreshOutcome: Equatable, Sendable {
  /// A git load that began after the request landed; reply with a fresh `list`.
  case loaded
  case timedOut
  case cancelled
}

extension RemoteHostRouter {
  static let worktreeDeletePollInterval: Duration = .milliseconds(100)
  /// How long a `worktree.delete` waits for the app's outcome (dirty check,
  /// delete script and removal), local and ssh.
  static let worktreeDeleteTimeout: Duration = .seconds(300)
  /// How long a `worktrees.refresh` waits for a fresh git load.
  static let worktreesRefreshTimeout: Duration = .seconds(60)

  /// Waits for one remote delete's entry to settle. Leaving the roster alone is
  /// never success: the app settles such an entry as `.failed`.
  static func runWorktreeDelete(
    clock: any Clock<Duration>,
    deletion: @escaping @MainActor @Sendable () -> AppFeature.RemoteWorktreeDeletion?
  ) async -> RemoteWorktreeDeleteOutcome {
    let settled = await poll(every: worktreeDeletePollInterval, within: worktreeDeleteTimeout, clock: clock) {
      () -> AppFeature.RemoteWorktreeDeletion? in
      guard let entry = deletion(), entry.isSettled else { return nil }
      return entry
    }
    guard !Task.isCancelled else { return .cancelled }
    switch settled {
    case .deleted: return .deleted
    case .failed(let code, let message): return .failed(code: code, message: message)
    case nil, .checking, .deleting: return .timedOut
    }
  }

  /// `runWorktreeDelete`, then on every exit `consume` once the entry has
  /// settled, or `abandon` while it still runs: the app keeps the entry as the
  /// `worktree_busy` guard and drops it when the delete ends.
  static func awaitWorktreeDelete(
    clock: any Clock<Duration>,
    deletion: @escaping @MainActor @Sendable () -> AppFeature.RemoteWorktreeDeletion?,
    consume: @MainActor () -> Void,
    abandon: @MainActor () -> Void
  ) async -> RemoteWorktreeDeleteOutcome {
    let outcome = await runWorktreeDelete(clock: clock, deletion: deletion)
    if deletion()?.isSettled == false {
      abandon()
    } else {
      consume()
    }
    return outcome
  }

  /// One frame a settled `worktree.delete` sends.
  nonisolated enum WorktreeDeleteReply: Equatable, Sendable {
    case deleted(RemoteWorktreeDeleteMessage)
    case error(RemoteErrorMessage)
  }

  /// The reply for a wait's outcome; nil for a cancelled wait (no reply).
  nonisolated static func worktreeDeleteReply(
    for outcome: RemoteWorktreeDeleteOutcome,
    start: RemoteWorktreeDeleteStart,
    requestID: Int?
  ) -> WorktreeDeleteReply? {
    switch outcome {
    case .deleted:
      return .deleted(
        RemoteWorktreeDeleteMessage(
          id: requestID, worktreeId: start.worktreeID.rawValue, repositoryId: start.repositoryID.rawValue))
    case .failed(let code, let message):
      return .error(RemoteErrorMessage(id: requestID, message: message, code: code))
    case .timedOut:
      return .error(
        RemoteErrorMessage(
          id: requestID,
          message: "the delete is still running on the Mac; the worktree may disappear from the list later",
          code: RemoteWorktreeDeleteErrorCode.timeout))
    case .cancelled:
      return nil
    }
  }

  /// Waits until a git load that began after the request (`started` is the
  /// generation read before the refresh was sent) has landed.
  static func runWorktreesRefresh(
    after started: Int,
    clock: any Clock<Duration>,
    completed: @escaping @MainActor @Sendable () -> Int
  ) async -> RemoteWorktreesRefreshOutcome {
    let loaded = await poll(every: worktreeDeletePollInterval, within: worktreesRefreshTimeout, clock: clock) {
      completed() > started ? true : nil
    }
    guard !Task.isCancelled else { return .cancelled }
    return loaded == true ? .loaded : .timedOut
  }

  /// The `refresh_timeout` error of a `worktrees.refresh`.
  nonisolated static func worktreesRefreshTimeoutError(requestID: Int?) -> RemoteErrorMessage {
    RemoteErrorMessage(
      id: requestID, message: "the refresh is still running on the Mac; send list again later",
      code: RemoteWorktreeDeleteErrorCode.refreshTimeout)
  }
}
