import Foundation
import Testing

@testable import supacode

struct AgentSessionRecordApplyingTests {
  private static let firstID = "0b6d3f0e-6a2f-4c55-9b0e-3f5e2a1c7d10"
  private static let secondID = "7a1f2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"

  private static let claudeFirst = AgentSessionRecord(agent: "claude", sessionID: firstID)
  private static let claudeSecond = AgentSessionRecord(agent: "claude", sessionID: secondID)
  private static let codexFirst = AgentSessionRecord(agent: "codex", sessionID: firstID)

  @Test func startedSetsTheRecordOnAnEmptyPane() {
    #expect(AgentSessionRecord.applying(.started(Self.claudeFirst), to: nil) == Self.claudeFirst)
  }

  @Test func startedAlwaysReplacesTheRecord() {
    // The last SessionStart wins: claude `/clear` gives a new id, and another
    // agent started in the same pane takes the pane over.
    #expect(AgentSessionRecord.applying(.started(Self.claudeSecond), to: Self.claudeFirst) == Self.claudeSecond)
    #expect(AgentSessionRecord.applying(.started(Self.codexFirst), to: Self.claudeFirst) == Self.codexFirst)
    #expect(AgentSessionRecord.applying(.started(Self.claudeFirst), to: Self.claudeFirst) == Self.claudeFirst)
  }

  @Test func endedWithTheMatchingIDClears() {
    let update = AgentSessionUpdate.ended(agent: "claude", sessionID: Self.firstID)
    #expect(AgentSessionRecord.applying(update, to: Self.claudeFirst) == nil)
  }

  @Test func endedWithoutAnIDClearsTheSameAgent() {
    let update = AgentSessionUpdate.ended(agent: "codex", sessionID: nil)
    #expect(AgentSessionRecord.applying(update, to: Self.codexFirst) == nil)
  }

  @Test func lateEndOfAnOldSessionKeepsItsReplacement() {
    // `/clear` sends the old id's end; if it lands after the new start it must
    // not clear the new record.
    let update = AgentSessionUpdate.ended(agent: "claude", sessionID: Self.firstID)
    #expect(AgentSessionRecord.applying(update, to: Self.claudeSecond) == Self.claudeSecond)
  }

  @Test func endedForAnotherAgentKeepsTheRecord() {
    #expect(
      AgentSessionRecord.applying(.ended(agent: "codex", sessionID: nil), to: Self.claudeFirst) == Self.claudeFirst)
    #expect(
      AgentSessionRecord.applying(.ended(agent: "codex", sessionID: Self.firstID), to: Self.claudeFirst)
        == Self.claudeFirst)
  }

  @Test func endedOnAnEmptyPaneStaysEmpty() {
    #expect(AgentSessionRecord.applying(.ended(agent: "claude", sessionID: nil), to: nil) == nil)
    #expect(AgentSessionRecord.applying(.ended(agent: "claude", sessionID: Self.firstID), to: nil) == nil)
  }

  @Test func recordRoundTripsThroughJSONWithStableKeys() throws {
    let data = try JSONEncoder().encode(Self.claudeFirst)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.contains("\"agent\":\"claude\""))
    #expect(json.contains("\"sessionID\":\"\(Self.firstID)\""))
    #expect(try JSONDecoder().decode(AgentSessionRecord.self, from: data) == Self.claudeFirst)
  }
}
