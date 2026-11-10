import CryptoKit
import Foundation
import SupacodeSettingsShared
import SystemConfiguration

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
  /// The name Supacode Remote shows for this Mac, raw from the file; nil when
  /// missing or not a string. `displayName(configured:computerName:)` applies it.
  let hostName: String?

  private enum CodingKeys: String, CodingKey {
    case enabled, relayURL, hostKey, hostName
    case lanSetting = "lan"
  }

  init(enabled: Bool, relayURL: URL, hostKey: String, lan: Bool? = nil, hostName: String? = nil) {
    self.enabled = enabled
    self.relayURL = relayURL
    self.hostKey = hostKey
    self.lanSetting = lan
    self.hostName = hostName
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try container.decode(Bool.self, forKey: .enabled)
    relayURL = try container.decode(URL.self, forKey: .relayURL)
    hostKey = try container.decode(String.self, forKey: .hostKey)
    lanSetting = try container.decodeIfPresent(Bool.self, forKey: .lanSetting)
    // A hand-edited name of the wrong type must not turn remote access off.
    hostName = try? container.decodeIfPresent(String.self, forKey: .hostName)
  }

  // MARK: - Host identity and name (docs/plans/2026-11-10-remote-multi-host-design.md)

  /// The longest host name sent; the relay cuts again and its cut is authoritative.
  static let maxHostNameLength = 64

  /// This Mac's stable relay id (ИД1): the first 16 lowercase hex characters of
  /// SHA-256 over a fixed prefix and the hardware UUID, so a copied config file
  /// never makes two Macs share an id and the raw UUID never reaches the relay.
  /// nil when there is no hardware UUID; the relay then files the Mac as `default`.
  static func hostID(hardwareUUID: String?) -> String? {
    guard let hardwareUUID, !hardwareUUID.isEmpty else { return nil }
    let digest = SHA256.hash(data: Data(("supacode-remote-host-v1:" + hardwareUUID).utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return String(hex.prefix(16))
  }

  /// The id of the Mac this process runs on.
  static var currentHostID: String? { hostID(hardwareUUID: HardwareInfo.uuid) }

  /// The Mac's computer name from the system configuration store, which does
  /// no network lookup (`Host.current()` can block on name resolution).
  static var computerName: String {
    (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
  }

  /// A host name by the ИД4 rules: control characters (category Cc, so emoji
  /// joiners survive) become spaces, surrounding whitespace is trimmed, the
  /// result is cut to `maxHostNameLength` characters. nil when nothing is left.
  static func normalizedHostName(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let spaced = String(
      String.UnicodeScalarView(
        raw.unicodeScalars.map { $0.properties.generalCategory == .control ? " " : $0 }))
    let trimmed = spaced.trimmingCharacters(in: .whitespacesAndNewlines)
    let cut = String(trimmed.prefix(maxHostNameLength))
    return cut.isEmpty ? nil : cut
  }

  /// The name this Mac goes by (ИД4): the configured name, or the computer name
  /// when it is missing or blank. Empty only when both are blank.
  static func displayName(configured: String?, computerName: String) -> String {
    normalizedHostName(configured) ?? normalizedHostName(computerName) ?? ""
  }

  /// Query characters left unescaped: RFC 3986 unreserved only, so `+`, `&`,
  /// `=` and `#` in a name never change how the relay splits the query.
  private static let queryValueAllowed = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  /// The relay `/host` URL with this Mac's `id` and `name` in the query (ИД2):
  /// existing `id` and `name` items are replaced, every other item is kept. `id`
  /// is omitted when nil, `name` when it normalizes to nothing.
  static func hostURL(base: URL, hostID: String?, name: String) -> URL {
    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
    // Compare decoded names: the relay reads `%69d` as `id`.
    var items = (components.percentEncodedQueryItems ?? []).filter {
      let name = $0.name.removingPercentEncoding ?? $0.name
      return name != "id" && name != "name"
    }
    let encode = { (value: String) in value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? "" }
    if let hostID { items.append(URLQueryItem(name: "id", value: encode(hostID))) }
    if let name = normalizedHostName(name) { items.append(URLQueryItem(name: "name", value: encode(name))) }
    components.percentEncodedQueryItems = items.isEmpty ? nil : items
    return components.url ?? base
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

  /// The relay keeps one host per Mac and every Supacode on the Mac reads the
  /// same config, so a second copy (a dev build from DerivedData, an agent's test
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
  /// This Mac's relay id (ИД1); nil connects as the legacy host `default`.
  private let hostID: String?
  /// The name sent in the URL of every new attempt; `rename(_:)` updates it.
  private(set) var hostName: String
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
    hostID: String?,
    hostName: String,
    onText: @escaping (String) -> Void,
    onConnectionChange: @escaping (Bool) -> Void
  ) {
    self.config = config
    self.hostID = hostID
    self.hostName = hostName
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

  /// Stores the name for the next attempt's URL and, while a socket is open
  /// or opening, tells the relay at once with the `@` control frame (ИД3), so
  /// no phone loses its terminals over a rename.
  func rename(_ name: String) {
    hostName = name
    guard task != nil else { return }
    send(RemoteHostFrame.renameFrame(name: name))
    relayLogger.info("Remote access host renamed")
  }

  private func run() async {
    var attempt = 0
    while !Task.isCancelled {
      // Built per attempt, so a reconnect carries the latest name. Never logged:
      // the relay URL is private.
      var request = URLRequest(url: RemoteAccessConfig.hostURL(base: config.relayURL, hostID: hostID, name: hostName))
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
      // Another Supacode with this Mac's id took over the host slot (the relay
      // keeps one socket per host id). Reconnecting would replace it in turn and
      // the two would flap forever.
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
