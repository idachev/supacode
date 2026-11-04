import Foundation

/// Owns the app's one `RemoteHostRouter` so Settings can apply a changed
/// `remote-access.json` without an app restart. The app hands it the start
/// closure at launch; until then (and in tests) every call is a no-op.
@MainActor
final class RemoteAccessHostController {
  static let shared = RemoteAccessHostController()

  private var makeRouter: (() -> RemoteHostRouter?)?
  private(set) var router: RemoteHostRouter?

  nonisolated deinit {}

  /// Remembers how to start the host and starts it once.
  func configure(start: @escaping () -> RemoteHostRouter?) {
    makeRouter = start
    restart()
  }

  /// Stops the running host (never two at once), then starts a new one when
  /// the file and this copy of the app allow it.
  func restart() {
    stop()
    router = makeRouter?()
  }

  func stop() {
    router?.stop()
    router = nil
  }

  var status: RemoteAccessHostStatus {
    let rawOverride = ProcessInfo.processInfo.environment[RemoteAccessConfig.overrideVariable]
    let override: RemoteAccessHostStatus.Override =
      switch rawOverride?.trimmingCharacters(in: .whitespaces) {
      case "1": .forcedOn
      case "0": .forcedOff
      default: .none
      }
    return RemoteAccessHostStatus(
      mayHost: RemoteAccessConfig.mayHost(bundlePath: Bundle.main.bundlePath, override: rawOverride),
      override: override,
      isRunning: router != nil,
      isRelayConnected: router?.isRelayConnected ?? false,
      lanPort: router?.lanPort,
      isLANStarting: router?.isLANStarting ?? false
    )
  }
}
