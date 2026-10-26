import Foundation
import Testing

@testable import supacode

/// `AgentSessionUpdate.from(_:)`: which presence events change a pane's
/// resumable session record. `applying(_:to:)` is covered by
/// `AgentSessionRecordApplyingTests`.
struct AgentSessionUpdateFromTests {
  private static let sessionID = "0b7c2f4e-6a1d-4c39-9e57-2d8f1a3b5c60"

  private func event(
    agent: String,
    _ name: AgentHookEvent.EventName,
    pid: pid_t? = 4242,
    sessionID: String? = Self.sessionID,
    endReason: String? = nil
  ) -> AgentHookEvent {
    AgentHookEvent(
      agent: agent,
      event: name.rawValue,
      surfaceID: UUID(),
      pid: pid,
      sessionID: sessionID,
      endReason: endReason
    )
  }

  @Test(arguments: ["claude", "codex", "grok", "antigravity"])
  func sessionStartWithIDAndPidStartsARecord(agent: String) {
    #expect(
      AgentSessionUpdate.from(event(agent: agent, .sessionStart))
        == .started(AgentSessionRecord(agent: agent, sessionID: Self.sessionID))
    )
  }

  @Test func sessionStartWithoutPidIsIgnored() {
    #expect(AgentSessionUpdate.from(event(agent: "claude", .sessionStart, pid: nil)) == nil)
  }

  @Test func sessionStartWithoutSessionIDIsIgnored() {
    #expect(AgentSessionUpdate.from(event(agent: "claude", .sessionStart, sessionID: nil)) == nil)
  }

  @Test(arguments: ["prompt_input_exit", "clear", "logout"])
  func claudeExplicitExitEnds(reason: String) {
    #expect(
      AgentSessionUpdate.from(event(agent: "claude", .sessionEnd, endReason: reason))
        == .ended(agent: "claude", sessionID: Self.sessionID)
    )
  }

  @Test func claudeEndCarriesANilSessionIDThrough() {
    #expect(
      AgentSessionUpdate.from(event(agent: "claude", .sessionEnd, sessionID: nil, endReason: "clear"))
        == .ended(agent: "claude", sessionID: nil)
    )
  }

  @Test(arguments: [String?.none, "other", "bogus"])
  func claudeEndWithoutAnExplicitExitKeepsTheRecord(reason: String?) {
    #expect(AgentSessionUpdate.from(event(agent: "claude", .sessionEnd, endReason: reason)) == nil)
  }

  @Test(arguments: [String?.none, "other"])
  func codexAnyEndEnds(reason: String?) {
    #expect(
      AgentSessionUpdate.from(event(agent: "codex", .sessionEnd, endReason: reason))
        == .ended(agent: "codex", sessionID: Self.sessionID)
    )
  }

  @Test func grokShutdownNeverEnds() {
    #expect(AgentSessionUpdate.from(event(agent: "grok", .sessionEnd, endReason: "shutdown")) == nil)
  }

  @Test func antigravityEndNeverEnds() {
    #expect(AgentSessionUpdate.from(event(agent: "antigravity", .sessionEnd, endReason: "prompt_input_exit")) == nil)
  }

  @Test(arguments: ["copilot", "opencode", "pi", "unknown"])
  func unsupportedAgentsAreIgnored(agent: String) {
    #expect(AgentSessionUpdate.from(event(agent: agent, .sessionStart)) == nil)
    #expect(AgentSessionUpdate.from(event(agent: agent, .sessionEnd, endReason: "prompt_input_exit")) == nil)
  }

  @Test(arguments: [
    AgentHookEvent.EventName.busy, .awaitingInput, .idle, .notification, .error, .compacting,
  ])
  func otherEventsAreIgnored(name: AgentHookEvent.EventName) {
    #expect(AgentSessionUpdate.from(event(agent: "claude", name, endReason: "prompt_input_exit")) == nil)
  }

  @Test func unknownEventNameIsIgnored() {
    let unknown = AgentHookEvent(
      agent: "claude", event: "future_event", surfaceID: UUID(), pid: 4242, sessionID: Self.sessionID)
    #expect(AgentSessionUpdate.from(unknown) == nil)
  }
}
