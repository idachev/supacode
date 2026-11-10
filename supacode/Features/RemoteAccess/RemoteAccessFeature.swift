import ComposableArchitecture
import Foundation

/// The Remote Access settings pane: shows whether this copy hosts and how the
/// host is doing, edits `enabled` / `lan` in `remote-access.json` (applied by
/// restarting the host) and `hostName` (applied live by renaming the host).
/// Keys stay on disk; the pane only copies the phone's connection key to the
/// pasteboard.
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
    /// A write of the file runs (a toggle apply or a host name save). One write
    /// runs at a time; a change of the other kind meanwhile waits for it.
    var isApplying = false
    /// The toggles changed during a write: apply their latest state when it ends.
    var isApplyPending = false
    /// The "Mac name" field as typed.
    var hostNameDraft = ""
    /// The field's placeholder: the name the host uses when the file sets none.
    var computerName = ""
    /// A host name save runs or waits for the running write.
    var isSavingHostName = false
    /// The trimmed name the running save writes ("" removes the key).
    var hostNameInFlight: String?
    /// The trimmed name submitted during another write; saved when it ends, latest wins.
    var pendingHostName: String?

    /// The name the file will hold once the running and waiting saves end.
    var targetHostName: String {
      pendingHostName ?? hostNameInFlight ?? (file.hostName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  enum Action {
    /// The pane is visible: read now and keep polling until the task ends.
    case task
    case refreshed(file: RemoteAccessFileStatus, host: RemoteAccessHostStatus)
    case enabledToggled(Bool)
    case lanToggled(Bool)
    case hostNameDraftChanged(String)
    /// Return in the field or focus left it.
    case hostNameSubmitted
    case hostNameSaved(file: RemoteAccessFileStatus)
    case hostNameSaveFailed(String)
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
        state.computerName = client.computerName()
        return .run { [client, clock] send in
          while !Task.isCancelled {
            await send(.refreshed(file: client.fileStatus(), host: await client.hostStatus()))
            try await clock.sleep(for: Self.pollInterval)
          }
        }

      case .refreshed(var file, let host):
        // While a write runs or waits, the toggles show what was asked, not the disk.
        if state.isApplying || state.isApplyPending {
          file.enabled = state.file.enabled
          file.lan = state.file.lan
        }
        // The poll follows the file only while the field holds the saved name,
        // so it never overwrites typing.
        if !state.isSavingHostName, state.hostNameDraft == (state.file.hostName ?? "") {
          state.hostNameDraft = file.hostName ?? ""
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
        if !state.isApplyPending {
          state.file = file
        }
        return startPendingWrite(&state)

      case .applyFailed(let message):
        state.isApplying = false
        state.isApplyPending = false
        state.errorMessage = message
        return .merge(
          .run { [client] send in
            await send(.refreshed(file: client.fileStatus(), host: await client.hostStatus()))
          },
          startPendingWrite(&state)
        )

      case .hostNameDraftChanged(let draft):
        state.hostNameDraft = draft
        return .none

      case .hostNameSubmitted:
        guard state.file.isConfigured else { return .none }
        let name = state.hostNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != state.targetHostName else { return .none }
        state.hostNameDraft = name
        state.errorMessage = nil
        guard !state.isApplying else {
          state.pendingHostName = name
          state.isSavingHostName = true
          return .none
        }
        return saveHostName(name, &state)

      case .hostNameSaved(var file):
        state.isApplying = false
        state.hostNameInFlight = nil
        state.isSavingHostName = state.pendingHostName != nil
        if state.isApplyPending {
          file.enabled = state.file.enabled
          file.lan = state.file.lan
        }
        state.file = file
        return startPendingWrite(&state)

      case .hostNameSaveFailed(let message):
        state.isApplying = false
        state.hostNameInFlight = nil
        state.isSavingHostName = state.pendingHostName != nil
        state.errorMessage = message
        return startPendingWrite(&state)

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

  /// Starts the write that waited for the one that just ended: the toggles
  /// first, then the host name. An error the ended write showed stays.
  private func startPendingWrite(_ state: inout State) -> Effect<Action> {
    if state.isApplyPending {
      state.isApplyPending = false
      let errorMessage = state.errorMessage
      let effect = apply(&state)
      state.errorMessage = errorMessage
      return effect
    }
    if let name = state.pendingHostName {
      state.pendingHostName = nil
      return saveHostName(name, &state)
    }
    return .none
  }

  /// Writes the trimmed name ("" removes the key), then renames the running
  /// host to the name it now goes by, without a restart.
  private func saveHostName(_ name: String, _ state: inout State) -> Effect<Action> {
    state.isApplying = true
    state.isSavingHostName = true
    state.hostNameInFlight = name
    let configured = name.isEmpty ? nil : name
    return .run { [client] send in
      do {
        try await client.writeHostName(configured)
      } catch {
        await send(.hostNameSaveFailed(error.localizedDescription))
        return
      }
      let displayName = RemoteAccessConfig.displayName(configured: configured, computerName: client.computerName())
      await client.renameHost(displayName)
      await send(.hostNameSaved(file: client.fileStatus()))
    }
  }

  /// Writes both flags, then restarts the host so they take effect now. One
  /// write runs at a time; a toggle during one is applied after it, latest wins.
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
