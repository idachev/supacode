import Foundation

/// The request waits in flight per phone (`tab.new`, `worktree.new`,
/// `worktree.delete`, `worktrees.refresh`), cancelled together when that
/// phone's connection ends so a reused connId never gets a stale answer.
/// Cancelling a wait stops only the answer: a creation or deletion the app
/// started goes on and keeps its `worktree_busy` guard until it settles.
nonisolated struct RemoteRequestWaits {
  private var byConn: [String: [UUID: Task<Void, Never>]] = [:]

  /// The phones with a wait in flight.
  var connIDs: [String] { Array(byConn.keys) }

  /// Records `task` as one of `connID`'s waits, under `waitID`.
  mutating func insert(_ task: Task<Void, Never>, waitID: UUID, connID: String) {
    byConn[connID, default: [:]][waitID] = task
  }

  /// Forgets a wait that ended on its own.
  mutating func remove(waitID: UUID, connID: String) {
    byConn[connID]?[waitID] = nil
  }

  /// Cancels every wait of `connID`; they send nothing.
  mutating func cancel(connID: String) {
    guard let waits = byConn.removeValue(forKey: connID) else { return }
    for wait in waits.values { wait.cancel() }
  }
}
