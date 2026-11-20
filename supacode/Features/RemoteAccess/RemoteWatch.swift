import Foundation

/// When a watching connection gets a pushed `list` (`watch`,
/// `docs/remote-access-protocol.md`): every `interval` the host compares the
/// current snapshot with the last `list` it sent to that connection. A change
/// in tab titles only (an agent TUI rewrites its title several times a second)
/// goes out at most once per `titleInterval`; any other change at the next tick.
nonisolated enum RemoteWatch {
  static let interval: Duration = .milliseconds(250)
  static let titleInterval: Duration = .seconds(2)

  enum Change: Equatable, Sendable { case none, titlesOnly, structural }

  /// How `new` differs from the `list` last sent; the request `id` never
  /// counts. `old` nil (nothing sent on this connection yet) is `.structural`.
  static func change(from old: RemoteListMessage?, to new: RemoteListMessage) -> Change {
    guard let old else { return .structural }
    let (oldList, newList) = (withoutID(old), withoutID(new))
    if oldList == newList { return .none }
    return withoutTabTitles(oldList) == withoutTabTitles(newList) ? .titlesOnly : .structural
  }

  /// Whether a tick sends: structural always; titles only after `titleInterval` since the last send.
  static func sends(_ change: Change, sinceLastSend: Duration) -> Bool {
    switch change {
    case .none: false
    case .titlesOnly: sinceLastSend >= titleInterval
    case .structural: true
    }
  }

  private static func withoutID(_ list: RemoteListMessage) -> RemoteListMessage {
    RemoteListMessage(
      id: nil, repos: list.repos, sections: list.sections, canRefreshWorktrees: list.canRefreshWorktrees,
      loadFailures: list.loadFailures)
  }

  /// `list` with every `tabs[].title` blanked; every other field kept.
  private static func withoutTabTitles(_ list: RemoteListMessage) -> RemoteListMessage {
    let repos = list.repos.map { repository in
      RemoteRepository(
        id: repository.id, name: repository.name, group: repository.group,
        worktrees: repository.worktrees.map { worktree in
          RemoteWorktree(
            id: worktree.id, name: worktree.name, branch: worktree.branch, status: worktree.status,
            focused: worktree.focused, title: worktree.title, working: worktree.working,
            tabs: worktree.tabs.map { tab in
              RemoteTab(
                id: tab.id, contentId: tab.contentId, title: "", focused: tab.focused, working: tab.working,
                readOnly: tab.readOnly, agents: tab.agents, busy: tab.busy)
            },
            canDeleteWorktree: worktree.canDeleteWorktree, layout: worktree.layout)
        },
        rowIds: repository.rowIds, canCreateWorktree: repository.canCreateWorktree)
    }
    return RemoteListMessage(
      id: list.id, repos: repos, sections: list.sections, canRefreshWorktrees: list.canRefreshWorktrees,
      loadFailures: list.loadFailures)
  }
}

/// The router's watching connections, each with the last `list` it got (a
/// push or a `list` reply) and the time since then, counted in ticks.
nonisolated struct RemoteWatchers {
  private struct Record {
    var lastSent: RemoteListMessage?
    var sinceLastSend: Duration = .zero
  }

  private var records: [String: Record] = [:]

  var isEmpty: Bool { records.isEmpty }
  var connIDs: [String] { records.keys.sorted() }

  /// `connID` watches. A repeated `watch` keeps its record, so an unchanged
  /// snapshot is not sent again.
  mutating func start(_ connID: String) {
    if records[connID] == nil { records[connID] = Record() }
  }

  mutating func end(_ connID: String) {
    records[connID] = nil
  }

  mutating func removeAll() {
    records.removeAll()
  }

  /// A `list` reply to `connID`: it counts as the last sent when `connID` watches.
  mutating func recordSent(_ list: RemoteListMessage, to connID: String) {
    guard records[connID] != nil else { return }
    records[connID] = Record(lastSent: list)
  }

  /// The last `list` `connID` got; nil when it watches without one or does not watch.
  func lastSent(to connID: String) -> RemoteListMessage? {
    records[connID]?.lastSent
  }

  /// One tick, `elapsed` after the previous one: the watchers that get `list`
  /// now (`RemoteWatch.sends`), sorted, each recorded as sent.
  mutating func tick(_ list: RemoteListMessage, elapsed: Duration) -> [String] {
    var sending: [String] = []
    for connID in connIDs {
      guard var record = records[connID] else { continue }
      record.sinceLastSend += elapsed
      let change = RemoteWatch.change(from: record.lastSent, to: list)
      if RemoteWatch.sends(change, sinceLastSend: record.sinceLastSend) {
        record = Record(lastSent: list)
        sending.append(connID)
      }
      records[connID] = record
    }
    return sending
  }
}
