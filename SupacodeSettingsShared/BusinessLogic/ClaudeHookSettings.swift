import Foundation

nonisolated enum ClaudeHookSettings {
  /// Canonical hook map for Claude. One composite command per (event,
  /// matcher) slot keeps the prune-and-replace cycle idempotent.
  static func hooksByEvent() throws -> [String: [JSONValue]] {
    try AgentHookPayloadSupport.extractHookGroups(
      from: ClaudeHooksPayload(),
      invalidConfiguration: ClaudeHookSettingsError.invalidConfiguration
    )
  }
}

nonisolated enum ClaudeHookSettingsError: Error {
  case invalidConfiguration
}

// MARK: - Hook payload.

// Atomic state-set: UserPromptSubmit / PreToolUse fire `busy`; PostToolUse
// fires `idle` so the shimmer tracks active tool execution, not the whole turn
// (the socket debounces idle to bridge between-tool gaps). AskUserQuestion /
// ExitPlanMode / PermissionRequest overwrite to `awaitingInput`; Stop and SessionEnd
// reset to `idle`. The pid liveness sweep is the safety net for crashed turns.
// Claude tracks tool execution; Codex and Kiro track work at turn level.
private nonisolated struct ClaudeHooksPayload: Encodable {
  static let awaitingInputToolMatcher = "AskUserQuestion|ExitPlanMode"

  private static let busy = AgentHookSettingsCommand.compositeCommand(
    events: [.busy], forwardStdinAsNotification: false, agent: .claude)
  private static let idle = AgentHookSettingsCommand.compositeCommand(
    events: [.idle], forwardStdinAsNotification: false, agent: .claude)
  private static let notify = AgentHookSettingsCommand.compositeCommand(
    events: [], forwardStdinAsNotification: true, agent: .claude)
  private static let awaitingInput = AgentHookSettingsCommand.compositeCommand(
    events: [.awaitingInput], forwardStdinAsNotification: false, agent: .claude)
  private static let stop = AgentHookSettingsCommand.claudeStopCommand(agent: .claude)
  // PostCompact is intentionally NOT mapped: compaction finishing is not turn
  // completion. `SessionStart(source: compact)` is what ends the compacting state.
  private static let compacting = AgentHookSettingsCommand.compositeCommand(
    events: [.compacting], forwardStdinAsNotification: false, agent: .claude)
  // SessionStart and SessionEnd capture the session id (and the end `reason`) for
  // the agent session resume after a reboot.
  private static let sessionStart = AgentHookSettingsCommand.compositeCommand(
    events: [.sessionStart], forwardStdinAsNotification: false, agent: .claude, capturesSession: true)
  private static let sessionEndAndIdle = AgentHookSettingsCommand.compositeCommand(
    events: [.sessionEnd, .idle], forwardStdinAsNotification: false, agent: .claude, capturesSession: true)

  let hooks: [String: [AgentHookGroup]] = [
    "SessionStart": [
      .init(hooks: [.init(command: Self.sessionStart, timeout: AgentHookSettingsCommand.timeoutSeconds)])
    ],
    "UserPromptSubmit": [
      .init(hooks: [.init(command: Self.busy, timeout: AgentHookSettingsCommand.timeoutSeconds)])
    ],
    "PreToolUse": [
      .init(matcher: "", hooks: [.init(command: Self.busy, timeout: AgentHookSettingsCommand.timeoutSeconds)]),
      // Array-order: matched-by-name fires AFTER matcher-"", so awaiting wins.
      .init(
        matcher: Self.awaitingInputToolMatcher,
        hooks: [.init(command: Self.awaitingInput, timeout: AgentHookSettingsCommand.timeoutSeconds)]
      ),
    ],
    "PostToolUse": [
      .init(matcher: "", hooks: [.init(command: Self.idle, timeout: AgentHookSettingsCommand.timeoutSeconds)])
    ],
    "PermissionRequest": [
      .init(hooks: [.init(command: Self.awaitingInput, timeout: AgentHookSettingsCommand.timeoutSeconds)])
    ],
    "Notification": [
      .init(
        matcher: "^(permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input)$",
        hooks: [.init(command: Self.awaitingInput, timeout: AgentHookSettingsCommand.timeoutSeconds)]),
      .init(
        matcher: "",
        hooks: [.init(command: Self.notify, timeout: AgentHookSettingsCommand.timeoutSeconds)]),
    ],
    "PreCompact": [
      .init(hooks: [.init(command: Self.compacting, timeout: AgentHookSettingsCommand.timeoutSeconds)])
    ],
    "Stop": [
      .init(hooks: [.init(command: Self.stop, timeout: AgentHookSettingsCommand.timeoutSeconds)])
    ],
    "SessionEnd": [
      .init(
        matcher: "", hooks: [.init(command: Self.sessionEndAndIdle, timeout: AgentHookSettingsCommand.timeoutSeconds)])
    ],
  ]
}
