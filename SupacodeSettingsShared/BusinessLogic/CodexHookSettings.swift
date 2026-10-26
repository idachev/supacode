import Foundation

nonisolated enum CodexHookSettings {
  /// Single canonical hook map for Codex. See `ClaudeHookSettings` for the
  /// composite-command rationale (one Supacode-managed entry per slot →
  /// idempotent prune-and-replace).
  static func hooksByEvent() throws -> [String: [JSONValue]] {
    try AgentHookPayloadSupport.extractHookGroups(
      from: CodexHooksPayload(),
      invalidConfiguration: CodexHookSettingsError.invalidConfiguration
    )
  }
}

nonisolated enum CodexHookSettingsError: Error {
  case invalidConfiguration
}

// MARK: - Hook payload.

// Turn-level activity only — Codex doesn't expose PreToolUse/PostToolUse
// at a useful granularity (Bash-only), so a single `busy` at submit and
// a single `idle` + notify at stop is the cleanest model. SessionStart
// fires on the first turn rather than on session open (openai/codex#15266),
// so the badge appears once the user submits a prompt. SessionEnd fires
// only on `/exit` and Ctrl-C (codex 0.164), never on HUP or TERM, so the
// badge still clears via the pid liveness sweep when Codex is killed.
// SessionStart and SessionEnd capture the session id for the agent session
// resume after a reboot; an explicit SessionEnd clears the record.
private nonisolated struct CodexHooksPayload: Encodable {
  private static let busy = AgentHookSettingsCommand.compositeCommand(
    events: [.busy], forwardStdinAsNotification: false, agent: .codex)
  private static let idleAndNotify = AgentHookSettingsCommand.compositeCommand(
    events: [.idle], forwardStdinAsNotification: true, agent: .codex)
  private static let sessionStart = AgentHookSettingsCommand.compositeCommand(
    events: [.sessionStart], forwardStdinAsNotification: false, agent: .codex, capturesSession: true)
  private static let sessionEnd = AgentHookSettingsCommand.compositeCommand(
    events: [.sessionEnd], forwardStdinAsNotification: false, agent: .codex, capturesSession: true)

  let hooks: [String: [AgentHookGroup]] = [
    "SessionStart": [
      .init(hooks: [.init(command: Self.sessionStart, timeout: AgentHookSettingsCommand.timeoutSeconds)])
    ],
    "UserPromptSubmit": [
      .init(hooks: [.init(command: Self.busy, timeout: AgentHookSettingsCommand.timeoutSeconds)])
    ],
    "Stop": [
      .init(hooks: [.init(command: Self.idleAndNotify, timeout: AgentHookSettingsCommand.timeoutSeconds)])
    ],
    "SessionEnd": [
      .init(hooks: [.init(command: Self.sessionEnd, timeout: AgentHookSettingsCommand.timeoutSeconds)])
    ],
  ]
}
