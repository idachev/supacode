import Foundation

/// A tab in which an agent waits for input: everything the notification and opening the terminal need.
nonisolated struct RemoteAwaitingTab: Equatable, Sendable {
  let contentId: String
  let repositoryId: String
  let worktreeId: String
  let worktreeName: String
  let tabTitle: String
  let agent: String
  var hasReminder = false
}

/// When an agent **starts** to wait for input.
///
/// A notification goes out only on the transition to `awaitingInput`. While a tab stays in that
/// state, new `list` replies give no second one; once it leaves the state (or the tab vanishes)
/// its next wait is a new event. The first snapshot after init or `reset()` only records who
/// waits; it starts nothing.
/// Port of `supacode-remote/.../alerts/AwaitingTracker.kt`.
nonisolated struct RemoteAwaitingTracker: Equatable, Sendable {
  struct Changes: Equatable, Sendable {
    /// Started to wait: a notification.
    var started: [RemoteAwaitingTab]
    /// No longer wait: their notification goes.
    var ended: [String]
  }

  /// The tabs that wait now, by content id. nil: no snapshot seen yet.
  private var awaiting: [String: RemoteAwaitingTab]?

  /// The activity string of a waiting agent on the wire.
  private static let awaitingInput = "awaitingInput"

  /// The first snapshot after init or reset only records who waits; it starts nothing.
  mutating func update(_ repos: [RemoteClientRepository]) -> Changes {
    var now: [String: RemoteAwaitingTab] = [:]
    for repo in repos {
      for worktree in repo.worktrees {
        for tab in worktree.tabs {
          guard let agent = tab.agents.first(where: { $0.activity == Self.awaitingInput }) else { continue }
          now[tab.contentId] = RemoteAwaitingTab(
            contentId: tab.contentId, repositoryId: repo.id, worktreeId: worktree.id,
            worktreeName: Self.worktreeName(worktree),
            tabTitle: tab.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Tab" : tab.title,
            agent: agent.agent, hasReminder: tab.inputReminder != nil)
        }
      }
    }
    defer { awaiting = now }
    guard let before = awaiting else { return Changes(started: [], ended: []) }
    let started = now.values.filter { before[$0.contentId] == nil }.sorted { $0.contentId < $1.contentId }
    let ended = before.keys.filter { now[$0] == nil }.sorted()
    return Changes(started: started, ended: ended)
  }

  /// Switching the Mac or closing the window: the content ids whose notifications go.
  mutating func reset() -> [String] {
    defer { awaiting = nil }
    return (awaiting ?? [:]).keys.sorted()
  }

  private static func worktreeName(_ worktree: RemoteClientWorktree) -> String {
    if let title = worktree.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
    return worktree.name
  }
}
