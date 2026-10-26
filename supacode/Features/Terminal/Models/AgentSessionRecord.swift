import Foundation

/// The coding agent session last started in a pane, persisted on the content
/// side so a restored pane whose zmx session died can type the agent's resume
/// command. `agent` is a `SkillAgent` rawValue, like `SurfaceAgentRecord`, so a
/// future enum rename never breaks decode.
nonisolated struct AgentSessionRecord: Codable, Equatable, Sendable {
  let agent: String
  let sessionID: String

  /// Folds one presence-derived update into a pane's record. A start always
  /// replaces the record (the last SessionStart wins). An end clears it only
  /// when it names the same agent and either carries no id or the stored one,
  /// so a late end of an old session never clears its replacement.
  static func applying(_ update: AgentSessionUpdate, to current: AgentSessionRecord?) -> AgentSessionRecord? {
    switch update {
    case .started(let record):
      return record
    case .ended(let agent, let sessionID):
      guard let current, current.agent == agent else { return current }
      guard sessionID == nil || sessionID == current.sessionID else { return current }
      return nil
    }
  }
}

/// A change to a pane's `AgentSessionRecord`, derived from a presence hook event.
nonisolated enum AgentSessionUpdate: Equatable, Sendable {
  case started(AgentSessionRecord)
  case ended(agent: String, sessionID: String?)
}
