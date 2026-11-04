import AppKit
import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

nonisolated private let settingsLogger = SupaLogger("RemoteAccess")

/// What the Remote Access settings pane shows about `remote-access.json`. Read
/// without the router's filtering (`RemoteAccessConfig.load()` hides a disabled
/// file), and never carries the host key or the client key themselves.
nonisolated struct RemoteAccessFileStatus: Equatable, Sendable {
  enum Presence: Equatable, Sendable {
    case missing
    case malformed
    case present
  }

  var presence: Presence
  var enabled: Bool
  var lan: Bool
  var relayURL: String?
  var hasHostKey: Bool
  var hasConnectionKey: Bool

  static let missing = Self(
    presence: .missing, enabled: false, lan: true, relayURL: nil, hasHostKey: false, hasConnectionKey: false)

  /// The file holds what the host needs, so the toggles can act on it.
  var isConfigured: Bool { presence == .present && hasHostKey && relayURL != nil }
}

/// The running host as the settings pane sees it.
nonisolated struct RemoteAccessHostStatus: Equatable, Sendable {
  /// `SUPACODE_REMOTE_ACCESS` as it decides hosting.
  enum Override: Equatable, Sendable {
    case none
    case forcedOn
    case forcedOff
  }

  var mayHost: Bool
  var override: Override
  var isRunning: Bool
  var isRelayConnected: Bool
  var lanPort: UInt16?
  /// The LAN listener is still loading its identity or getting ready.
  var isLANStarting = false

  static let stopped = Self(mayHost: false, override: .none, isRunning: false, isRelayConnected: false, lanPort: nil)
}

/// Reads and edits `remote-access.json` for the settings pane. Every other key
/// in the file (the relay URL, the host key) is kept as it is.
nonisolated enum RemoteAccessConfigFile {
  enum WriteError: Error, LocalizedError {
    case notConfigured
    case writeFailed

    var errorDescription: String? {
      switch self {
      case .notConfigured: "The remote access configuration file is missing or unreadable."
      case .writeFailed: "Could not write the remote access configuration file."
      }
    }
  }

  static func readStatus(
    configURL: URL = RemoteAccessConfig.defaultFileURL,
    clientKeyURL: URL = RemoteAccessConfig.clientKeyFileURL
  ) -> RemoteAccessFileStatus {
    let hasConnectionKey = connectionKey(from: clientKeyURL) != nil
    guard let data = try? Data(contentsOf: configURL) else {
      var status = RemoteAccessFileStatus.missing
      status.hasConnectionKey = hasConnectionKey
      return status
    }
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      (try? JSONDecoder().decode(RemoteAccessConfig.self, from: data)) != nil
    else {
      var status = RemoteAccessFileStatus.missing
      status.presence = .malformed
      status.hasConnectionKey = hasConnectionKey
      return status
    }
    let relayURL = (object["relayURL"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    return RemoteAccessFileStatus(
      presence: .present,
      enabled: object["enabled"] as? Bool ?? false,
      lan: object["lan"] as? Bool ?? true,
      relayURL: relayURL,
      hasHostKey: (object["hostKey"] as? String).map { !$0.isEmpty } ?? false,
      hasConnectionKey: hasConnectionKey
    )
  }

  /// Sets `enabled` and `lan`, keeps every other key, and replaces the file
  /// atomically with mode 0600 (it holds the host key).
  static func write(enabled: Bool, lan: Bool, to url: URL = RemoteAccessConfig.defaultFileURL) throws {
    guard
      let data = try? Data(contentsOf: url),
      var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw WriteError.notConfigured }
    object["enabled"] = enabled
    object["lan"] = lan
    let output = try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    let fileManager = FileManager.default
    let scratch = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
    guard fileManager.createFile(atPath: scratch.path, contents: output, attributes: [.posixPermissions: 0o600])
    else { throw WriteError.writeFailed }
    guard rename(scratch.path, url.path) == 0 else {
      try? fileManager.removeItem(at: scratch)
      throw WriteError.writeFailed
    }
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    settingsLogger.info("Remote access settings saved: enabled \(enabled), LAN \(lan)")
  }

  /// The phone's whole connection key (`<relay host>/<client key>`), trimmed.
  static func connectionKey(from url: URL = RemoteAccessConfig.clientKeyFileURL) -> String? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

/// File, pasteboard and host access for `RemoteAccessFeature`.
nonisolated struct RemoteAccessClient: Sendable {
  var fileStatus: @Sendable () -> RemoteAccessFileStatus
  var writeFlags: @Sendable (_ enabled: Bool, _ lan: Bool) async throws -> Void
  var hostStatus: @MainActor @Sendable () -> RemoteAccessHostStatus
  /// Stops the host and starts it again from the file as it is now.
  var restartHost: @MainActor @Sendable () -> Void
  /// Copies the connection key to the general pasteboard; false when there is none.
  var copyConnectionKey: @MainActor @Sendable () -> Bool
  var revealConfigFolder: @MainActor @Sendable () -> Void
}

nonisolated extension RemoteAccessClient: DependencyKey {
  static let liveValue = Self(
    fileStatus: { RemoteAccessConfigFile.readStatus() },
    writeFlags: { try RemoteAccessConfigFile.write(enabled: $0, lan: $1) },
    hostStatus: { RemoteAccessHostController.shared.status },
    restartHost: { RemoteAccessHostController.shared.restart() },
    copyConnectionKey: {
      guard let key = RemoteAccessConfigFile.connectionKey() else { return false }
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      return pasteboard.setString(key, forType: .string)
    },
    revealConfigFolder: {
      let config = RemoteAccessConfig.defaultFileURL
      if FileManager.default.fileExists(atPath: config.path) {
        NSWorkspace.shared.activateFileViewerSelecting([config])
      } else {
        NSWorkspace.shared.open(config.deletingLastPathComponent())
      }
    }
  )

  static let testValue = Self(
    fileStatus: { .missing },
    writeFlags: { _, _ in },
    hostStatus: { .stopped },
    restartHost: {},
    copyConnectionKey: { false },
    revealConfigFolder: {}
  )
}
