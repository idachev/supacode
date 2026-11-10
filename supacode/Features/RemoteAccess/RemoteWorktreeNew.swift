import Foundation

/// The `code` values of the `error` frames a `worktree.new` can get
/// (`docs/remote-access-protocol.md`, `### worktree.new`).
nonisolated enum RemoteWorktreeNewErrorCode {
  static let invalid = "worktree_invalid"
  static let busy = "worktree_busy"
  static let unsupported = "worktree_unsupported"
  static let failed = "worktree_failed"
  static let timeout = "worktree_timeout"
}

/// A checked `worktree.new`: the repository and the trimmed branch name.
nonisolated struct RemoteWorktreeNewRequest: Equatable, Sendable {
  /// The longest branch name a client may send, in UTF-8 bytes after trimming.
  static let maxNameBytes = 200

  let repositoryID: String
  let name: String

  /// One remote wait per repository and case-insensitive name (`worktree_busy`).
  var inFlightKey: String {
    repositoryID + "\n" + name.lowercased()
  }

  /// The request, or why it is refused before the app sees it: `repositoryId`
  /// missing, not a string or empty; `name` missing, not a string, empty after
  /// trimming or over `maxNameBytes`.
  static func resolve(_ message: RemoteInboundMessage) -> Result<Self, RemoteWorktreeNewRejection> {
    guard let repositoryID = message.repositoryId?.value, !repositoryID.isEmpty else {
      return .failure(.missingRepository)
    }
    guard let raw = message.name?.value else { return .failure(.missingName) }
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return .failure(.missingName) }
    guard name.utf8.count <= maxNameBytes else { return .failure(.nameTooLong) }
    return .success(Self(repositoryID: repositoryID, name: name))
  }
}

/// Why a `worktree.new` is refused by the host before the app runs it; the
/// client gets `message` with `code`, and the Mac shows no alert.
nonisolated enum RemoteWorktreeNewRejection: Error, Equatable, Sendable {
  case missingRepository
  case missingName
  case nameTooLong
  case unknownRepository
  case notGitRepository
  case repositoryBeingRemoved
  case busy

  var code: String {
    switch self {
    case .missingRepository, .missingName, .nameTooLong, .unknownRepository: RemoteWorktreeNewErrorCode.invalid
    case .notGitRepository, .repositoryBeingRemoved: RemoteWorktreeNewErrorCode.unsupported
    case .busy: RemoteWorktreeNewErrorCode.busy
    }
  }

  var message: String {
    switch self {
    case .missingRepository: "worktree.new needs a repositoryId"
    case .missingName: "worktree.new needs a branch name"
    case .nameTooLong: "the branch name is too long"
    case .unknownRepository: "no such repository"
    case .notGitRepository: "worktrees are only supported for git repositories"
    case .repositoryBeingRemoved: "the repository is being removed"
    case .busy: "a worktree with this branch is already being created"
    }
  }

  /// The rejection for a repository lookup, or nil when a worktree may be
  /// created in it (local or ssh).
  static func check(found: Bool, isGitRepository: Bool, isBeingRemoved: Bool) -> Self? {
    guard found else { return .unknownRepository }
    guard isGitRepository else { return .notGitRepository }
    if isBeingRemoved { return .repositoryBeingRemoved }
    return nil
  }
}

/// A creation the app accepted: the pending id its outcome is filed under
/// (`AppFeature.State.remoteWorktreeCreations`) and whether the repository is
/// reached over ssh (it then opens no tab of its own).
nonisolated struct RemoteWorktreeNewStart: Equatable, Sendable {
  let pendingID: Worktree.ID
  let isSSH: Bool
}

/// The first terminal tab of a created worktree, as `list` reports it.
nonisolated struct RemoteWorktreeNewTab: Equatable, Sendable {
  let tabId: String
  let contentId: String
}

/// How a `worktree.new` wait ended (`RemoteHostRouter.runWorktreeNew`).
nonisolated enum RemoteWorktreeNewOutcome: Equatable, Sendable {
  /// The worktree exists; `tab` is nil when its first tab failed or did not
  /// appear in time (still a success).
  case created(worktreeID: Worktree.ID, name: String, tab: RemoteWorktreeNewTab?)
  /// The app reported a failure with this message.
  case failed(message: String)
  /// No outcome within `worktreeNewTimeout`.
  case timedOut
  /// The phone's connection ended; nobody is answered.
  case cancelled
}

/// What a `worktree.new` wait reads from the app, injected so the wait can be
/// tested without a live store (`RemoteSnapshotSource.worktreeNewProbes`).
struct RemoteWorktreeNewProbes: Sendable {
  /// The creation's entry in `AppFeature.State.remoteWorktreeCreations`.
  let creation: @MainActor @Sendable () -> AppFeature.RemoteWorktreeCreation?
  /// Local: the worktree's first terminal tab once its layout lists one.
  let firstTab: @MainActor @Sendable (Worktree.ID) -> RemoteWorktreeNewTab?
  /// ssh: nil while the roster does not list the worktree yet; then opens one
  /// tab the way `tab.new` does and returns its id, or why it could not.
  let openTab: @MainActor @Sendable (Worktree.ID) -> Result<UUID, RemoteTabNewRejection>?
  /// ssh: the opened tab's content once the layout lists it and its grid is sized.
  let tabContent: @MainActor @Sendable (UUID, Worktree.ID) -> UUID?
}

extension RemoteHostRouter {
  static let worktreeNewPollInterval: Duration = .milliseconds(100)

  /// How long a `worktree.new` waits for the app's outcome (license check
  /// included); with `worktreeNewTabTimeout` every request is answered within 310 s.
  nonisolated static func worktreeNewTimeout(isSSH: Bool) -> Duration {
    isSSH ? .seconds(290) : .seconds(300)
  }

  /// How long a created worktree's first tab may take to appear before the
  /// reply goes out without it (ssh: the roster reload plus opening the tab).
  nonisolated static func worktreeNewTabTimeout(isSSH: Bool) -> Duration {
    isSSH ? .seconds(20) : .seconds(10)
  }

  /// Waits for one `worktree.new`: phase 1 for the app's outcome, phase 2 for
  /// the first terminal tab (local: the one Supacode opened itself; ssh: one
  /// opened here once the roster lists the worktree). `.cancelled` when the
  /// wait was cancelled (the phone left).
  static func runWorktreeNew(
    isSSH: Bool,
    clock: any Clock<Duration>,
    probes: RemoteWorktreeNewProbes
  ) async -> RemoteWorktreeNewOutcome {
    let settled = await poll(
      every: worktreeNewPollInterval, within: worktreeNewTimeout(isSSH: isSSH), clock: clock
    ) { () -> AppFeature.RemoteWorktreeCreation? in
      guard let creation = probes.creation(), creation.isSettled else { return nil }
      return creation
    }
    guard !Task.isCancelled else { return .cancelled }
    let worktreeID: Worktree.ID
    let name: String
    switch settled {
    case nil, .creating:
      return .timedOut
    case .failed(let message):
      return .failed(message: message)
    case .tabFailed(let id, let created):
      return .created(worktreeID: id, name: created, tab: nil)
    case .created(let id, let created):
      worktreeID = id
      name = created
    }
    let tab =
      isSSH
      ? await openSSHTab(worktreeID: worktreeID, clock: clock, probes: probes)
      : await waitForFirstTab(worktreeID: worktreeID, clock: clock, probes: probes)
    guard !Task.isCancelled else { return .cancelled }
    return .created(worktreeID: worktreeID, name: name, tab: tab)
  }

  private nonisolated enum WorktreeTabProbe: Sendable {
    case tab(RemoteWorktreeNewTab)
    case none
  }

  /// Local phase 2: the tab Supacode opened itself (`ensureInitialTab`), or
  /// nil once the tab failed or `worktreeNewTabTimeout` passed.
  private static func waitForFirstTab(
    worktreeID: Worktree.ID,
    clock: any Clock<Duration>,
    probes: RemoteWorktreeNewProbes
  ) async -> RemoteWorktreeNewTab? {
    let found = await poll(
      every: worktreeNewPollInterval, within: worktreeNewTabTimeout(isSSH: false), clock: clock
    ) { () -> WorktreeTabProbe? in
      if let tab = probes.firstTab(worktreeID) { return .tab(tab) }
      if case .tabFailed = probes.creation() { return WorktreeTabProbe.none }
      return nil
    }
    guard case .tab(let tab) = found else { return nil }
    return tab
  }

  /// ssh phase 2, one `worktreeNewTabTimeout` for all of it: wait for the
  /// roster to list the worktree, open one tab as `tab.new` does, then wait for
  /// its content. Nil on a rejection or at the deadline.
  private static func openSSHTab(
    worktreeID: Worktree.ID,
    clock: any Clock<Duration>,
    probes: RemoteWorktreeNewProbes
  ) async -> RemoteWorktreeNewTab? {
    let opened = OpenedTab()
    let found = await poll(
      every: worktreeNewPollInterval, within: worktreeNewTabTimeout(isSSH: true), clock: clock
    ) { () -> WorktreeTabProbe? in
      if opened.tabID == nil {
        switch probes.openTab(worktreeID) {
        case nil: return nil
        case .failure: return WorktreeTabProbe.none
        case .success(let tabID): opened.tabID = tabID
        }
      }
      guard let tabID = opened.tabID, let contentID = probes.tabContent(tabID, worktreeID) else { return nil }
      return .tab(RemoteWorktreeNewTab(tabId: tabID.uuidString, contentId: contentID.uuidString))
    }
    guard case .tab(let tab) = found else { return nil }
    return tab
  }

  /// The tab an ssh wait opened, kept across its poll ticks so it opens once.
  @MainActor
  private final class OpenedTab {
    var tabID: UUID?

    nonisolated deinit {}
  }

  /// One frame a settled `worktree.new` sends.
  nonisolated enum WorktreeNewReply: Equatable, Sendable {
    case worktree(RemoteWorktreeNewMessage)
    case error(RemoteErrorMessage)
  }

  /// The reply for a wait's outcome; nil for a cancelled wait (no reply).
  nonisolated static func worktreeNewReply(
    for outcome: RemoteWorktreeNewOutcome,
    repositoryID: String,
    requestID: Int?
  ) -> WorktreeNewReply? {
    switch outcome {
    case .created(let worktreeID, let name, let tab):
      return .worktree(
        RemoteWorktreeNewMessage(
          id: requestID, repositoryId: repositoryID, worktreeId: worktreeID.rawValue, name: name,
          tabId: tab?.tabId, contentId: tab?.contentId))
    case .failed(let message):
      return .error(RemoteErrorMessage(id: requestID, message: message, code: RemoteWorktreeNewErrorCode.failed))
    case .timedOut:
      return .error(
        RemoteErrorMessage(
          id: requestID,
          message: "worktree creation is still running on the Mac; it will appear in the list when it finishes",
          code: RemoteWorktreeNewErrorCode.timeout))
    case .cancelled:
      return nil
    }
  }
}
