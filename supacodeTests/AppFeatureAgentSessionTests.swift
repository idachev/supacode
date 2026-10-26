import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

/// A presence hook event that starts or explicitly ends a resumable agent session
/// reaches the pane's content as a terminal command, and presence still gets it.
@MainActor
struct AppFeatureAgentSessionTests {
  private static let sessionID = "0b7c2f4e-6a1d-4c39-9e57-2d8f1a3b5c60"

  private func makeStore(sent: LockIsolated<[TerminalClient.Command]>) -> TestStoreOf<AppFeature> {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    }
    store.exhaustivity = .off
    return store
  }

  // `strict: false`: presence fans out further actions only when its row state
  // changes (a start does; an end or idle on an empty presence state does not).
  @Test(.dependencies) func sessionStartSendsTheUpdateAndForwardsPresence() async {
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = makeStore(sent: sent)
    let surfaceID = UUID()
    let event = AgentHookEvent(
      agent: "claude", event: "session_start", surfaceID: surfaceID, pid: 4242, sessionID: Self.sessionID)

    await store.send(.terminalEvent(.agentHookEventReceived(event)))
    await store.receive(\.agentPresence.hookEventReceived)
    await store.skipReceivedActions(strict: false)
    await store.finish()

    let expected = TerminalClient.Command.updateAgentSession(
      surfaceID: surfaceID,
      update: .started(AgentSessionRecord(agent: "claude", sessionID: Self.sessionID))
    )
    #expect(sent.value.filter { $0 == expected }.count == 1)
  }

  @Test(.dependencies) func explicitExitSendsAnEndedUpdate() async {
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = makeStore(sent: sent)
    let surfaceID = UUID()
    let event = AgentHookEvent(
      agent: "claude", event: "session_end", surfaceID: surfaceID, pid: 4242,
      sessionID: Self.sessionID, endReason: "prompt_input_exit")

    await store.send(.terminalEvent(.agentHookEventReceived(event)))
    await store.receive(\.agentPresence.hookEventReceived)
    await store.skipReceivedActions(strict: false)
    await store.finish()

    #expect(
      sent.value.contains(
        .updateAgentSession(surfaceID: surfaceID, update: .ended(agent: "claude", sessionID: Self.sessionID))))
  }

  @Test(.dependencies) func eventWithoutASessionChangeSendsNoUpdate() async {
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = makeStore(sent: sent)
    let event = AgentHookEvent(agent: "claude", event: "idle", surfaceID: UUID(), pid: 4242)

    await store.send(.terminalEvent(.agentHookEventReceived(event)))
    await store.receive(\.agentPresence.hookEventReceived)
    await store.skipReceivedActions(strict: false)
    await store.finish()

    let updates = sent.value.filter {
      if case .updateAgentSession = $0 { return true }
      return false
    }
    #expect(updates.isEmpty)
  }
}
