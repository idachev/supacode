import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

// The remote `worktree.new` / `worktree.delete` state and the reducer helpers
// that drive it, kept out of AppFeature.swift.

extension AppFeature {
  /// The result of a remote delete's dirty check (`GitClientDependency.worktreeChanges`).
  nonisolated enum RemoteWorktreeDeleteCheck: Equatable, Sendable {
    case clean
    /// The `worktree_dirty` message.
    case dirty(message: String)
    /// Git failed; the error's description.
    case failed(message: String)
  }

  /// Where one remote `worktree.delete` stands. An entry moves only from
  /// `.checking` / `.deleting`; a settled entry is never overwritten. Any entry
  /// is the remote `worktree_busy` guard for its worktree.
  nonisolated enum RemoteWorktreeDeletion: Equatable, Sendable {
    /// The dirty check runs; `abandoned` once the remote host stopped waiting.
    case checking(abandoned: Bool)
    /// The app's delete runs (delete script, removal).
    case deleting(abandoned: Bool)
    case deleted
    /// Refused or failed, with the `error` frame's `code` and `message`.
    case failed(code: String, message: String)

    var isSettled: Bool {
      switch self {
      case .checking, .deleting: false
      case .deleted, .failed: true
      }
    }

    var isAbandoned: Bool {
      switch self {
      case .checking(let abandoned), .deleting(let abandoned): abandoned
      case .deleted, .failed: false
      }
    }

    /// Moves an unsettled entry to its outcome (only a `.deleting` one when
    /// `onlyWhileDeleting`), or removes it when the host abandoned it.
    static func settle(
      _ worktreeID: Worktree.ID, as outcome: Self, onlyWhileDeleting: Bool = true,
      in deletions: inout [Worktree.ID: Self]
    ) {
      switch deletions[worktreeID] {
      case .deleting(let abandoned):
        deletions[worktreeID] = abandoned ? nil : outcome
      case .checking(let abandoned) where !onlyWhileDeleting:
        deletions[worktreeID] = abandoned ? nil : outcome
      default:
        break
      }
    }

    /// Marks an unsettled entry abandoned; a settled entry is removed instead.
    static func abandon(_ worktreeID: Worktree.ID, in deletions: inout [Worktree.ID: Self]) {
      switch deletions[worktreeID] {
      case .checking: deletions[worktreeID] = .checking(abandoned: true)
      case .deleting: deletions[worktreeID] = .deleting(abandoned: true)
      case .some: deletions[worktreeID] = nil
      case nil: break
      }
    }

    /// The message of a delete whose worktree left the roster without a delete result.
    static let leftTheListMessage =
      "the worktree left the list before it was deleted (removed outside Supacode, or its repository was removed)"
  }

  /// Where one remote `worktree.new` stands. An entry moves only from
  /// `.creating`; a settled entry is never overwritten (except `.created` →
  /// `.tabFailed` when the first tab fails). A `.creating` entry is also the
  /// remote `worktree_busy` guard for its repository and name.
  nonisolated enum RemoteWorktreeCreation: Equatable, Sendable {
    /// Still being created. `name` is the trimmed branch name that was
    /// requested; `abandoned` once the remote host stopped waiting on it.
    case creating(repositoryID: Repository.ID, name: String, abandoned: Bool)
    case created(worktreeID: Worktree.ID, name: String)
    /// Created, but its first terminal tab could not be hosted.
    case tabFailed(worktreeID: Worktree.ID, name: String)
    case failed(message: String)

    /// The message a remote client gets when the Mac user cancels the creation.
    static let cancelledMessage = "Worktree creation was cancelled on the Mac."

    var isSettled: Bool {
      if case .creating = self { return false }
      return true
    }

    /// Moves a `.creating` entry to its outcome, or removes it when the remote
    /// host abandoned it (nobody waits for the outcome). An unknown or settled
    /// entry is left alone.
    static func settle(
      _ pendingID: Worktree.ID, as outcome: Self, in creations: inout [Worktree.ID: Self]
    ) {
      guard case .creating(_, _, let abandoned) = creations[pendingID] else { return }
      creations[pendingID] = abandoned ? nil : outcome
    }

    /// Marks a `.creating` entry abandoned; a settled entry is removed instead
    /// (the host only abandons a creation it believes still runs).
    static func abandon(_ pendingID: Worktree.ID, in creations: inout [Worktree.ID: Self]) {
      switch creations[pendingID] {
      case .creating(let repositoryID, let name, _):
        creations[pendingID] = .creating(repositoryID: repositoryID, name: name, abandoned: true)
      case .some:
        creations[pendingID] = nil
      case nil:
        break
      }
    }

    /// Whether a creation of this repository and (case-insensitive) name is
    /// still running, abandoned or not (`worktree_busy`).
    static func isInFlight(repositoryID: String, name: String, in creations: [Worktree.ID: Self]) -> Bool {
      let wanted = name.lowercased()
      return creations.values.contains { creation in
        guard case .creating(let repository, let creating, _) = creation else { return false }
        return repository.rawValue == repositoryID && creating.lowercased() == wanted
      }
    }
  }
}

// MARK: - Remote worktree.delete and worktree.new

extension AppFeature {
  /// Moves a remote `worktree.delete` entry out of `.deleting` (`RemoteWorktreeDeletion.settle`).
  func settleRemoteWorktreeDeletion(
    _ worktreeID: Worktree.ID, as outcome: RemoteWorktreeDeletion, state: inout State
  ) {
    RemoteWorktreeDeletion.settle(worktreeID, as: outcome, in: &state.remoteWorktreeDeletions)
  }

  /// The backstop: a checking or deleting entry whose worktree is in none of
  /// `repositories` vanished without a delete result (a refresh after a CLI
  /// delete, its repository removed or failing to load). A real delete set
  /// `.deleted` in `.worktreeDeleted` before its own `repositoriesChanged`.
  func settleRemoteWorktreeDeletionsOutside(
    _ repositories: IdentifiedArrayOf<Repository>, state: inout State
  ) {
    guard state.remoteWorktreeDeletions.values.contains(where: { !$0.isSettled }) else { return }
    let roster = Set(repositories.flatMap { $0.worktrees.map(\.id) })
    for (worktreeID, entry) in state.remoteWorktreeDeletions where !entry.isSettled && !roster.contains(worktreeID) {
      RemoteWorktreeDeletion.settle(
        worktreeID,
        as: .failed(code: RemoteWorktreeDeleteErrorCode.failed, message: RemoteWorktreeDeletion.leftTheListMessage),
        onlyWhileDeleting: false,
        in: &state.remoteWorktreeDeletions)
    }
  }

  /// A remote `worktree.delete` the host accepted: the dirty check first,
  /// except for an orphan whose directory is still absent now (nothing to
  /// lose), which the Mac also deletes without its script. `isMissing` is from
  /// the last load, so a directory that came back is checked like any other.
  func requestRemoteWorktreeDelete(
    worktreeID: Worktree.ID, repositoryID: Repository.ID, state: inout State
  ) -> Effect<Action> {
    guard let worktree = state.repositories.repositories[id: repositoryID]?.worktrees[id: worktreeID] else {
      let unknown = RemoteWorktreeDeleteRejection.unknownWorktree
      state.remoteWorktreeDeletions[worktreeID] = .failed(code: unknown.code, message: unknown.message)
      return .none
    }
    state.remoteWorktreeDeletions[worktreeID] = .checking(abandoned: false)
    // Host-aware, as `RepositoriesFeature.gitClient(for:)`: an ssh worktree is
    // checked on its host, with its remote path.
    let client = worktree.host.map { GitClientDependency.ssh(host: $0) } ?? gitClient
    let directory = worktree.workingDirectory
    // Only a local worktree is ever `isMissing` (ssh paths cannot be stat'd).
    let wasMissing = worktree.isMissing
    return .run { send in
      if wasMissing, !FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
        await send(.remoteWorktreeDeleteChecked(worktreeID: worktreeID, result: .clean))
        return
      }
      let result: RemoteWorktreeDeleteCheck
      do {
        let changes = try await client.worktreeChanges(directory)
        result = changes.message.map { .dirty(message: $0) } ?? .clean
      } catch {
        result = .failed(message: error.localizedDescription)
      }
      await send(.remoteWorktreeDeleteChecked(worktreeID: worktreeID, result: result))
    }
  }

  /// The dirty check's result: refuse, or re-check the delete rule on the
  /// current state (the Mac may have started its own delete, archived the
  /// worktree, or begun removing the repository meanwhile) and delete.
  func remoteWorktreeDeleteChecked(
    worktreeID: Worktree.ID, result: RemoteWorktreeDeleteCheck, state: inout State
  ) -> Effect<Action> {
    guard case .checking = state.remoteWorktreeDeletions[worktreeID] else { return .none }
    let failure: RemoteWorktreeDeletion?
    switch result {
    case .dirty(let message):
      failure = .failed(code: RemoteWorktreeDeleteErrorCode.dirty, message: message)
    case .failed(let message):
      failure = .failed(
        code: RemoteWorktreeDeleteErrorCode.failed, message: "could not check the worktree for changes: \(message)")
    case .clean:
      failure = nil
    }
    if let failure {
      RemoteWorktreeDeletion.settle(
        worktreeID, as: failure, onlyWhileDeleting: false, in: &state.remoteWorktreeDeletions)
      return .none
    }
    // `inFlight: false`: this request's own entry is not another delete.
    let recheck = RemoteWorktreeDeleteRejection.check(
      worktreeID: worktreeID.rawValue, in: state.repositories, inFlight: false)
    switch recheck {
    case .failure(let refused):
      RemoteWorktreeDeletion.settle(
        worktreeID, as: .failed(code: refused.code, message: refused.message), onlyWhileDeleting: false,
        in: &state.remoteWorktreeDeletions)
      return .none
    case .success(let start):
      return startRemoteWorktreeDelete(worktreeID: start.worktreeID, repositoryID: start.repositoryID, state: &state)
    }
  }

  /// The delete step: the Mac's own delete pipeline without its confirmation
  /// (the client confirmed), in the background (no Mac focus change), never
  /// deleting the local branch.
  func startRemoteWorktreeDelete(
    worktreeID: Worktree.ID, repositoryID: Repository.ID, state: inout State
  ) -> Effect<Action> {
    let abandoned = state.remoteWorktreeDeletions[worktreeID]?.isAbandoned ?? false
    state.remoteWorktreeDeletions[worktreeID] = .deleting(abandoned: abandoned)
    return .send(
      .repositories(.deleteSidebarItemConfirmed(worktreeID, repositoryID, background: true, keepBranch: true)))
  }

  /// Moves a remote `worktree.new` entry out of `.creating` (`RemoteWorktreeCreation.settle`).
  func settleRemoteWorktreeCreation(
    _ pendingID: Worktree.ID, as outcome: RemoteWorktreeCreation, state: inout State
  ) {
    RemoteWorktreeCreation.settle(pendingID, as: outcome, in: &state.remoteWorktreeCreations)
  }

  /// The first tab of a remotely created worktree failed: its entry (found by
  /// the real worktree id, as `bindWorktreeNewAck` binds the CLI ack) becomes `.tabFailed`.
  func markRemoteWorktreeTabFailed(_ worktreeID: Worktree.ID, state: inout State) {
    for (pendingID, creation) in state.remoteWorktreeCreations {
      guard case .created(worktreeID: worktreeID, name: let name) = creation else { continue }
      state.remoteWorktreeCreations[pendingID] = .tabFailed(worktreeID: worktreeID, name: name)
    }
  }

  /// A remote `worktree.new`: an explicit branch name (never `.random`), the
  /// repository's base ref and the global fetch setting, like the CLI's
  /// explicit-branch path, so the Mac's New Worktree prompt is bypassed. The
  /// Mac selects the new worktree (`background: false`), as its own button does.
  func requestRemoteWorktree(
    repositoryID: Repository.ID, name: String, pendingID: Worktree.ID, state: inout State
  ) -> Effect<Action> {
    state.remoteWorktreeCreations[pendingID] = .creating(repositoryID: repositoryID, name: name, abandoned: false)
    @Shared(.settingsFile) var settingsFile: SettingsFile
    return .send(
      .repositories(
        .createWorktreeInRepository(
          repositoryID: repositoryID,
          nameSource: .explicit(name),
          baseRefSource: .repositorySetting,
          fetchOrigin: settingsFile.global.fetchOriginBeforeWorktreeCreation,
          pendingID: pendingID,
          background: false,
          pin: false
        )
      )
    )
  }
}
