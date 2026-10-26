import Foundation
import SupacodeSettingsShared

nonisolated extension AgentSessionUpdate {
  /// SessionEnd reasons that mean the user left claude on purpose. `other`
  /// (HUP / TERM, a dying pty) keeps the record, so the pane resumes after a reboot.
  private static let claudeExplicitExitReasons: Set<String> = ["prompt_input_exit", "clear", "logout"]

  /// The record change a presence hook event implies, or nil when it implies none.
  /// Only claude, codex, grok and antigravity are resumable. A start needs a session
  /// id and a pid: the pid marks a hook that ran on this machine. An end clears only
  /// on an unambiguous explicit exit (claude's exit reasons, any codex end); grok and
  /// agy ends never clear, since resuming an ended session is harmless.
  static func from(_ event: AgentHookEvent) -> AgentSessionUpdate? {
    guard let agent = SkillAgent(rawValue: event.agent) else { return nil }
    switch agent {
    case .claude, .codex, .grok, .antigravity:
      break
    case .copilot, .hermes, .kimi, .kiro, .omp, .opencode, .pi:
      return nil
    }
    switch event.eventName {
    case .sessionStart:
      guard let sessionID = event.sessionID, event.pid != nil else { return nil }
      return .started(AgentSessionRecord(agent: agent.rawValue, sessionID: sessionID))
    case .sessionEnd:
      switch agent {
      case .claude:
        guard let reason = event.endReason, claudeExplicitExitReasons.contains(reason) else { return nil }
        return .ended(agent: agent.rawValue, sessionID: event.sessionID)
      case .codex:
        return .ended(agent: agent.rawValue, sessionID: event.sessionID)
      default:
        return nil
      }
    case .busy, .awaitingInput, .idle, .notification, .error, .compacting, nil:
      return nil
    }
  }
}
