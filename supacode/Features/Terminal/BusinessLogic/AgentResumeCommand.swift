import Foundation
import SupacodeSettingsShared

/// The text typed into a restored pane to resume its agent's session. The
/// first word stays bare so shell aliases apply; the id is re-validated and
/// shell-quoted; the trailing newline runs it.
nonisolated enum AgentResumeCommand {
  static func initialInput(for record: AgentSessionRecord) -> String? {
    guard UUID(uuidString: record.sessionID) != nil else { return nil }
    let quoted = SSHCommand.shellQuote(record.sessionID)
    switch SkillAgent(rawValue: record.agent) {
    case .claude: return "claude --resume \(quoted)\n"
    case .codex: return "codex resume \(quoted)\n"
    case .grok: return "grok --resume \(quoted)\n"
    case .antigravity: return "agy --conversation \(quoted)\n"
    default: return nil
    }
  }
}
