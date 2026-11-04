import Foundation

// The wire keys `t` (type) and `v` (version) are the protocol contract
// (docs/remote-access-protocol.md); Codable maps property names 1:1.
// swiftlint:disable identifier_name

/// Relay framing between Supacode and the Cloudflare relay: every text frame is
/// `<connId>\n<json>` (see `docs/remote-access-protocol.md`, "Relay framing").
nonisolated enum RemoteHostFrame {
  /// The connId that broadcasts a host frame to every phone.
  static let broadcastConnID = "*"

  static func parse(_ text: String) -> (connID: String, json: Data)? {
    guard let newline = text.firstIndex(of: "\n"), newline != text.startIndex else { return nil }
    let connID = String(text[..<newline])
    let json = Data(text[text.index(after: newline)...].utf8)
    return (connID, json)
  }

  static func encode(connID: String, payload: Data) -> String {
    connID + "\n" + (String(bytes: payload, encoding: .utf8) ?? "{}")
  }
}

/// One message a phone sends. Every field except `t` is optional; each handler
/// checks the ones it needs.
nonisolated struct RemoteInboundMessage: Decodable, Equatable, Sendable {
  let t: String
  var id: Int?
  var v: Int?
  var contentId: String?
  var scrollback: Int?
  var b64: String?
  /// `tab.new`: the worktree to open the tab in.
  var worktreeId: String?
  /// `conn.open` from the relay: the phone is on the Mac's network.
  var sameNetwork: Bool?
}

// MARK: - Outbound payloads

nonisolated struct RemoteHelloMessage: Encodable, Equatable, Sendable {
  var t = "hello"
  var v = 1
  let host: String
  /// Where a phone on the Mac's network can try the LAN shortcut; omitted otherwise.
  var lan: RemoteLANCandidate?
}

nonisolated struct RemoteLANCandidate: Encodable, Equatable, Sendable {
  let addrs: [String]
  let port: Int
  /// Lowercase hex SHA-256 of the LAN certificate the phone pins.
  let fp: String
  /// HMAC with the client key over the fingerprint: proves it was not swapped by the relay.
  let fpMac: String
}

nonisolated struct RemoteErrorMessage: Encodable, Equatable, Sendable {
  var t = "error"
  let id: Int?
  let message: String

  // Encode `id` as an explicit null so clients can match on it.
  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(t, forKey: .t)
    try container.encode(id, forKey: .id)
    try container.encode(message, forKey: .message)
  }

  private enum CodingKeys: String, CodingKey {
    case t, id, message
  }
}

nonisolated struct RemoteListMessage: Encodable, Equatable, Sendable {
  var t = "list"
  let id: Int?
  let repos: [RemoteRepository]
  /// The sidebar's sections in display order; see the protocol doc.
  var sections: [RemoteSection] = []
}

/// One sidebar section: a highlight (`active` / `pinned`, worktree rows from
/// any repository), a repository `group` header with its member repositories,
/// or an ungrouped `repository`. Absent fields are omitted on the wire.
nonisolated struct RemoteSection: Encodable, Equatable, Sendable {
  let kind: String
  var title: String?
  var collapsed: Bool?
  var worktreeIds: [String]?
  var repositoryIds: [String]?
  var repositoryId: String?
}

nonisolated struct RemoteRepository: Encodable, Equatable, Sendable {
  let id: String
  let name: String
  /// The sidebar repository group this repository sits in; omitted when none.
  var group: String?
  let worktrees: [RemoteWorktree]
  /// Worktree ids the sidebar lists under this repository, in order; rows
  /// hoisted into Active / Pinned are left out. Empty until set by the source.
  var rowIds: [String] = []
}

nonisolated struct RemoteWorktree: Encodable, Equatable, Sendable {
  let id: String
  let name: String
  let branch: String
  let status: String
  let focused: Bool
  let title: String?
  let working: Bool
  let tabs: [RemoteTab]
}

nonisolated struct RemoteTab: Encodable, Equatable, Sendable {
  let id: String
  let contentId: String
  let title: String
  let focused: Bool
  let working: Bool
  let readOnly: Bool
  let agents: [RemoteAgent]
}

nonisolated struct RemoteAgent: Encodable, Equatable, Sendable {
  let agent: String
  let activity: String
}

nonisolated struct RemoteAttachedMessage: Encodable, Equatable, Sendable {
  var t = "attached"
  let id: Int?
  let contentId: String
  let cols: Int
  let rows: Int
}

nonisolated struct RemoteSizeMessage: Encodable, Equatable, Sendable {
  var t = "size"
  let contentId: String
  let cols: Int
  let rows: Int
}

nonisolated struct RemoteDetachedMessage: Encodable, Equatable, Sendable {
  var t = "detached"
  let contentId: String
  let reason: String
}

nonisolated struct RemoteSuggestMessage: Encodable, Equatable, Sendable {
  var t = "suggest"
  let id: Int?
  let contentId: String
  let suggestions: [String]
}

/// The answer to `tab.new`: the new tab and the content the phone attaches to.
nonisolated struct RemoteTabNewMessage: Encodable, Equatable, Sendable {
  var t = "tab.new"
  let id: Int?
  let worktreeId: String
  let tabId: String
  let contentId: String
}

nonisolated enum RemoteJSON {
  static func encode(_ value: some Encodable) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    // Every payload here is a plain struct of strings, numbers and arrays, so
    // encoding cannot fail; fall back to an empty object rather than crash.
    return (try? encoder.encode(value)) ?? Data("{}".utf8)
  }

  static func decodeInbound(_ data: Data) -> RemoteInboundMessage? {
    try? JSONDecoder().decode(RemoteInboundMessage.self, from: data)
  }

  /// `out` messages for terminal bytes, split into base64 payloads of at most
  /// `chunkSize` raw bytes so one agent redraw never becomes one oversized
  /// frame. Built by hand: the content id is a UUID and base64 needs no JSON
  /// escaping, and this runs for every PTY chunk.
  static func outputMessages(contentID: String, bytes: [UInt8], chunkSize: Int = 64 * 1024) -> [String] {
    guard !bytes.isEmpty else { return [] }
    let prefix = "{\"t\":\"out\",\"contentId\":\"" + contentID + "\",\"b64\":\""
    return stride(from: 0, to: bytes.count, by: chunkSize).map { start in
      let end = min(start + chunkSize, bytes.count)
      return prefix + Data(bytes[start..<end]).base64EncodedString() + "\"}"
    }
  }
}

// swiftlint:enable identifier_name
