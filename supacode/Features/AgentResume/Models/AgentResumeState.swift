import ComposableArchitecture
import Foundation

/// The reducer's mirror of the manager's launch liveness capture. The manager's
/// `AgentResumeGate` is not observable, so the capture event sets this once.
nonisolated enum AgentResumeLiveness: Equatable, Sendable {
  /// The capture has not reported yet.
  case notCaptured
  /// The probe failed, or zmx cannot spawn: nothing resumes this launch.
  case probeFailed
  /// The `supa-*` zmx session names alive at launch.
  case captured(liveSessionNames: Set<String>)
}

/// One pane (tab content) that waits for its agent's resume after a restart.
nonisolated struct PendingAgentResume: Identifiable, Equatable, Sendable {
  let id: ContentID
  let worktreeID: Worktree.ID
  let tabID: TabID
  let repositoryName: String
  let worktreeName: String
  /// The stored title (`customTitle ?? title`); an unspawned tab has no live chrome.
  let tabTitle: String
  let agent: String
  let sessionID: String

  var shortSessionID: String { String(sessionID.prefix(8)) }
}

/// App-level agent resume state: the gate mirror and the pending list computed
/// from it. Content-specific, so it lives here and never in `LayoutFeature`.
@ObservableState
struct AgentResumeState: Equatable {
  var liveness: AgentResumeLiveness = .notCaptured
  /// Every content that spent its resume slot in this process.
  var claimed: Set<ContentID> = []
  var pending: IdentifiedArrayOf<PendingAgentResume> = []
  var didEvaluateAutoPresent = false
  var wakeQueue: [ContentID] = []
}
