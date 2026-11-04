import ComposableArchitecture
import Foundation

/// The Remote Access settings pane: shows whether this copy hosts and how the
/// host is doing, and edits `enabled` / `lan` in `remote-access.json`, applying
/// them by restarting the host. Keys stay on disk; the pane only copies the
/// phone's connection key to the pasteboard.
@Reducer
struct RemoteAccessFeature {
  /// How often the pane re-reads the file and the host while it is visible.
  nonisolated static let pollInterval: Duration = .seconds(2)
  /// How long the copy button says "Copied".
  nonisolated static let copiedFeedbackDuration: Duration = .seconds(2)

  @ObservableState
  struct State: Equatable {
    var file = RemoteAccessFileStatus.missing
    var host = RemoteAccessHostStatus.stopped
    var errorMessage: String?
    var connectionKeyCopied = false
    /// A write and host restart is running; toggles meanwhile only queue one more.
    var isApplying = false
    /// The toggles changed during an apply: apply their latest state when it ends.
    var isApplyPending = false
  }

  enum Action {
    /// The pane is visible: read now and keep polling until the task ends.
    case task
    case refreshed(file: RemoteAccessFileStatus, host: RemoteAccessHostStatus)
    case enabledToggled(Bool)
    case lanToggled(Bool)
    case applyFinished(file: RemoteAccessFileStatus, host: RemoteAccessHostStatus)
    case applyFailed(String)
    case copyConnectionKeyTapped
    case connectionKeyCopied(Bool)
    case copiedFeedbackEnded
    case revealConfigFolderTapped
  }

  private nonisolated enum CancelID: Hashable, Sendable {
    case copiedFeedback
  }

  @Dependency(RemoteAccessClient.self) private var client
  @Dependency(\.continuousClock) private var clock

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .task:
        return .run { [client, clock] send in
          while !Task.isCancelled {
            await send(.refreshed(file: client.fileStatus(), host: await client.hostStatus()))
            try await clock.sleep(for: Self.pollInterval)
          }
        }

      case .refreshed(var file, let host):
        // While an apply runs or waits, the toggles show what was asked, not the disk.
        if state.isApplying || state.isApplyPending {
          file.enabled = state.file.enabled
          file.lan = state.file.lan
        }
        state.file = file
        state.host = host
        return .none

      case .enabledToggled(let enabled):
        guard state.file.isConfigured, state.file.enabled != enabled else { return .none }
        state.file.enabled = enabled
        return apply(&state)

      case .lanToggled(let lan):
        guard state.file.isConfigured, state.file.lan != lan else { return .none }
        state.file.lan = lan
        return apply(&state)

      case .applyFinished(let file, let host):
        state.isApplying = false
        state.host = host
        guard !state.isApplyPending else {
          state.isApplyPending = false
          return apply(&state)
        }
        state.file = file
        return .none

      case .applyFailed(let message):
        state.isApplying = false
        state.isApplyPending = false
        state.errorMessage = message
        return .run { [client] send in
          await send(.refreshed(file: client.fileStatus(), host: await client.hostStatus()))
        }

      case .copyConnectionKeyTapped:
        return .run { [client] send in
          await send(.connectionKeyCopied(await client.copyConnectionKey()))
        }

      case .connectionKeyCopied(let copied):
        guard copied else {
          state.connectionKeyCopied = false
          state.errorMessage = "No connection key found in \(RemoteAccessFeature.clientKeyFileName)."
          return .none
        }
        state.connectionKeyCopied = true
        state.errorMessage = nil
        return .run { [clock] send in
          try await clock.sleep(for: Self.copiedFeedbackDuration)
          await send(.copiedFeedbackEnded)
        }
        .cancellable(id: CancelID.copiedFeedback, cancelInFlight: true)

      case .copiedFeedbackEnded:
        state.connectionKeyCopied = false
        return .none

      case .revealConfigFolderTapped:
        return .run { [client] _ in await client.revealConfigFolder() }
      }
    }
  }

  nonisolated static let clientKeyFileName = "remote-client-key.txt"

  /// Writes both flags, then restarts the host so they take effect now. One
  /// apply runs at a time; a toggle during it is applied after it, latest wins.
  private func apply(_ state: inout State) -> Effect<Action> {
    state.errorMessage = nil
    guard !state.isApplying else {
      state.isApplyPending = true
      return .none
    }
    state.isApplying = true
    let enabled = state.file.enabled
    let lan = state.file.lan
    return .run { [client] send in
      do {
        try await client.writeFlags(enabled, lan)
      } catch {
        await send(.applyFailed(error.localizedDescription))
        return
      }
      await client.restartHost()
      await send(.applyFinished(file: client.fileStatus(), host: await client.hostStatus()))
    }
  }
}
