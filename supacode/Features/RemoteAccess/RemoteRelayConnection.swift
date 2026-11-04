import Foundation
import SupacodeSettingsShared

nonisolated private let relayLogger = SupaLogger("RemoteAccess")

/// Remote access settings, read once at launch from `remote-access.json` in
/// the config directory (`~/.config/supacode`, or `$XDG_CONFIG_HOME/supacode`),
/// written by `remote-relay/scripts/gen-keys.mjs` with mode 0600.
nonisolated struct RemoteAccessConfig: Decodable, Equatable, Sendable {
  let enabled: Bool
  let relayURL: URL
  let hostKey: String
  /// The LAN shortcut for phones on the Mac's network; on unless set to false.
  var lan: Bool { lanSetting ?? true }
  private let lanSetting: Bool?

  private enum CodingKeys: String, CodingKey {
    case enabled, relayURL, hostKey
    case lanSetting = "lan"
  }

  init(enabled: Bool, relayURL: URL, hostKey: String, lan: Bool? = nil) {
    self.enabled = enabled
    self.relayURL = relayURL
    self.hostKey = hostKey
    self.lanSetting = lan
  }

  static var clientKeyFileURL: URL {
    SupacodePaths.configBaseDirectory.appending(path: "remote-client-key.txt")
  }

  /// The bare client key from the phone's connection key file
  /// (`<relay host>/<client key>`); the LAN shortcut derives its frame keys from it.
  static func loadClientKey(from url: URL = clientKeyFileURL) -> String? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let key = trimmed.split(separator: "/").last.map(String.init) ?? ""
    return key.isEmpty ? nil : key
  }

  static var defaultFileURL: URL {
    SupacodePaths.configBaseDirectory.appending(path: "remote-access.json")
  }

  /// Forces remote access on (`1`) or off (`0`) for this process.
  static let overrideVariable = "SUPACODE_REMOTE_ACCESS"

  /// The relay keeps one host and every Supacode on the Mac reads the same
  /// config, so a second copy (a dev build from DerivedData, an agent's test
  /// instance) would take the phone away from the real app. Only the app
  /// installed under `/Applications` (or `~/Applications`) hosts, unless the
  /// override variable says otherwise.
  static func mayHost(bundlePath: String, override: String?) -> Bool {
    switch override?.trimmingCharacters(in: .whitespaces) {
    case "1": return true
    case "0": return false
    default:
      let installedRoots = ["/Applications/", NSHomeDirectory() + "/Applications/"]
      return installedRoots.contains { bundlePath.hasPrefix($0) }
    }
  }

  /// nil when the file is missing, unreadable, malformed or disabled.
  static func load(from url: URL = defaultFileURL) -> RemoteAccessConfig? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    guard let config = try? JSONDecoder().decode(RemoteAccessConfig.self, from: data) else {
      relayLogger.warning("Ignoring malformed remote access config at \(url.path)")
      return nil
    }
    guard config.enabled, !config.hostKey.isEmpty else { return nil }
    return config
  }
}

/// The outbound host WebSocket to the relay. Reconnects with backoff, sends a
/// `ping` every 30 s (the relay answers `pong` without waking its object), and
/// hands every other text frame to `onText` on the main actor in arrival order.
@MainActor
final class RemoteRelayConnection {
  static let pingInterval: Duration = .seconds(30)
  static let maxBackoff: Duration = .seconds(30)
  static let livenessTimeout: Duration = .seconds(75)
  /// Sent by the relay to a host socket that a newer host connection replaced.
  static let replacedNotice = "replaced"

  private let config: RemoteAccessConfig
  private let session = URLSession(configuration: .default)
  private var task: URLSessionWebSocketTask?
  private var loop: Task<Void, Never>?
  private var lastReceive = ContinuousClock.now
  /// Whether the relay answered on the current socket.
  private(set) var isConnected = false
  private let onText: (String) -> Void
  private let onConnectionChange: (Bool) -> Void

  init(
    config: RemoteAccessConfig,
    onText: @escaping (String) -> Void,
    onConnectionChange: @escaping (Bool) -> Void
  ) {
    self.config = config
    self.onText = onText
    self.onConnectionChange = onConnectionChange
  }

  nonisolated deinit {}

  func start() {
    guard loop == nil else { return }
    loop = Task { [weak self] in await self?.run() }
  }

  func stop() {
    loop?.cancel()
    loop = nil
    task?.cancel(with: .goingAway, reason: nil)
    task = nil
    isConnected = false
  }

  func send(_ text: String) {
    guard let task else { return }
    task.send(.string(text)) { error in
      if let error { relayLogger.debug("Relay send failed: \(error.localizedDescription)") }
    }
  }

  private func run() async {
    var attempt = 0
    while !Task.isCancelled {
      var request = URLRequest(url: config.relayURL)
      request.setValue("Bearer \(config.hostKey)", forHTTPHeaderField: "Authorization")
      let socket = session.webSocketTask(with: request)
      socket.maximumMessageSize = 32 << 20
      task = socket
      socket.resume()
      lastReceive = .now
      // Half-open sockets (sleep, Wi-Fi change) never fail `receive()` on their
      // own: the relay answers every `ping` with `pong`, so silence for
      // `livenessTimeout` means the link is dead and the socket is dropped.
      let pinger = Task { [weak self] in
        // An early ping gets a `pong` at once, so the connected state shows
        // without waiting for the first interval.
        self?.send("ping")
        while !Task.isCancelled {
          try? await Task.sleep(for: Self.pingInterval)
          guard !Task.isCancelled, let self else { return }
          if ContinuousClock.now - self.lastReceive > Self.livenessTimeout {
            relayLogger.info("Remote relay went silent; reconnecting")
            socket.cancel(with: .goingAway, reason: nil)
            return
          }
          self.send("ping")
        }
      }
      var connected = false
      var replaced = false
      do {
        while !Task.isCancelled {
          let message = try await socket.receive()
          lastReceive = .now
          if !connected {
            connected = true
            attempt = 0
            relayLogger.info("Connected to remote relay")
            isConnected = true
            onConnectionChange(true)
          }
          guard case .string(let text) = message, text != "pong" else { continue }
          if text == Self.replacedNotice {
            replaced = true
            break
          }
          onText(text)
        }
      } catch {
        relayLogger.debug("Remote relay connection ended: \(error.localizedDescription)")
      }
      pinger.cancel()
      socket.cancel(with: .goingAway, reason: nil)
      if task === socket { task = nil }
      if connected {
        isConnected = false
        onConnectionChange(false)
      }
      // Another Supacode took over the host slot (the relay keeps one host).
      // Reconnecting would replace it in turn and the two would flap forever.
      if replaced {
        relayLogger.warning("Another Supacode instance is the remote access host now; this one stops")
        loop = nil
        return
      }
      guard !Task.isCancelled else { return }
      attempt += 1
      let delay = min(Duration.seconds(1 << min(attempt - 1, 5)), Self.maxBackoff)
      try? await Task.sleep(for: delay)
    }
  }
}
