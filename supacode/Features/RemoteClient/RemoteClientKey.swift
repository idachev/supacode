import Foundation

/// The connection key file of this Mac as a client of another Mac's Supacode:
/// `<relay host>/<client key>`, the same file the Android remote reads.
nonisolated struct RemoteClientKey: Equatable, Sendable {
  /// `relay.example.com`, or with `http://` / `https://` in front.
  let relayHost: String
  let key: String

  /// RFC 3986 unreserved only, so a host id never changes how the relay splits the query.
  private static let queryValueAllowed = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  /// The text of `remote-client-key.txt`: `<relay host>/<client key>`, split at the last
  /// slash. nil without a host or a key.
  static func parse(_ text: String) -> RemoteClientKey? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let slash = trimmed.lastIndex(of: "/") else { return nil }
    let host = String(trimmed[..<slash])
    let key = String(trimmed[trimmed.index(after: slash)...])
    // `http://host` has no key: its last slash is the scheme's, which leaves `http:/`.
    guard !host.isEmpty, !key.isEmpty, !host.hasSuffix("/") else { return nil }
    return RemoteClientKey(relayHost: host, key: key)
  }

  static func load(from url: URL = RemoteAccessConfig.clientKeyFileURL) -> RemoteClientKey? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return parse(text)
  }

  /// `wss://<host>/client[?host=<id>]`; `http://` in the file gives `ws://`.
  func clientURL(hostID: String?) -> URL? {
    var scheme = "wss"
    var bare = Substring(relayHost)
    if bare.hasPrefix("http://") {
      scheme = "ws"
      bare = bare.dropFirst("http://".count)
    } else if bare.hasPrefix("https://") {
      bare = bare.dropFirst("https://".count)
    }
    guard !bare.isEmpty, var components = URLComponents(string: "\(scheme)://\(bare)/client"),
      components.host?.isEmpty == false
    else { return nil }
    if let hostID, !hostID.isEmpty {
      components.percentEncodedQuery =
        "host=" + (hostID.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) ?? "")
    }
    return components.url
  }
}
