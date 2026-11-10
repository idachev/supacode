import Foundation

// The wire keys `t` (type) and `v` (version) are the protocol contract
// (docs/remote-access-protocol.md); Codable maps property names 1:1.
// swiftlint:disable identifier_name

/// Relay framing between Supacode and the Cloudflare relay: every text frame is
/// `<connId>\n<json>` (see `docs/remote-access-protocol.md`, "Relay framing").
nonisolated enum RemoteHostFrame {
  /// The connId that broadcasts a host frame to every phone.
  static let broadcastConnID = "*"
  /// The reserved connId of host → relay control frames (ИД3); never a phone's.
  static let controlConnID = "@"

  static func parse(_ text: String) -> (connID: String, json: Data)? {
    guard let newline = text.firstIndex(of: "\n"), newline != text.startIndex else { return nil }
    let connID = String(text[..<newline])
    let json = Data(text[text.index(after: newline)...].utf8)
    return (connID, json)
  }

  static func encode(connID: String, payload: Data) -> String {
    connID + "\n" + (String(bytes: payload, encoding: .utf8) ?? "{}")
  }

  /// `@\n{"t":"host.name","name":…}`: tells the relay this Mac's new name
  /// without a reconnect. The name is normalized (ИД4) and omitted when empty.
  static func renameFrame(name: String) -> String {
    let message = RemoteHostNameMessage(name: RemoteAccessConfig.normalizedHostName(name))
    return encode(connID: controlConnID, payload: RemoteJSON.encode(message))
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
  /// `tab.new`: the optional start size (`RemoteTabNewGrid.resolve`);
  /// `resize`: the requested size (`RemoteResizeRequest.resolve`).
  var cols: RemoteLenientInt?
  var rows: RemoteLenientInt?
  /// `conn.open` from the relay: the phone is on the Mac's network.
  var sameNetwork: Bool?
}

/// An optional integer field that never fails the message: a value that is not
/// an integer (a string, a fraction, out of range) decodes as nil, so one bad
/// optional field cannot drop the whole request.
nonisolated struct RemoteLenientInt: Decodable, Equatable, Sendable {
  let value: Int?

  init(_ value: Int?) {
    self.value = value
  }

  init(from decoder: any Decoder) throws {
    value = try? decoder.singleValueContainer().decode(Int.self)
  }
}

/// The grid a phone-opened tab starts at while the Mac does not show it.
nonisolated struct RemoteTabNewGrid: Equatable, Sendable {
  static let columnRange = 20...500
  static let rowRange = 5...200

  let columns: Int
  let rows: Int
  /// True when the phone asked for this size: the terminal takes it exactly,
  /// growing if needed. False for the default cap, which only shrinks.
  let exact: Bool

  /// The phone's `cols` × `rows`, clamped to `columnRange` × `rowRange`, when
  /// both are integers; otherwise the default cap `fallback`.
  static func resolve(cols: RemoteLenientInt?, rows: RemoteLenientInt?, fallback: (columns: Int, rows: Int)) -> Self {
    guard let columns = cols?.value, let rowCount = rows?.value else {
      return Self(columns: fallback.columns, rows: fallback.rows, exact: false)
    }
    return Self(
      columns: min(max(columns, columnRange.lowerBound), columnRange.upperBound),
      rows: min(max(rowCount, rowRange.lowerBound), rowRange.upperBound),
      exact: true)
  }
}

/// A client's `resize` of the terminal it is attached to, checked and clamped
/// to `RemoteTabNewGrid.columnRange` × `RemoteTabNewGrid.rowRange`.
nonisolated struct RemoteResizeRequest: Equatable, Sendable {
  let contentID: UUID
  let columns: Int
  let rows: Int

  /// Why a `resize` is ignored (logged on the host; the client gets no reply).
  /// A valid request the host cannot apply is answered instead (`Failure`).
  nonisolated enum Ignored: Error, Equatable {
    case notAttached
    case invalidSize
  }

  /// The request, or why it is ignored: a content other than `attached` (or
  /// none attached), or `cols` / `rows` missing or not an integer.
  static func resolve(_ message: RemoteInboundMessage, attached: UUID?) -> Result<Self, Ignored> {
    guard let attached, let raw = message.contentId, UUID(uuidString: raw) == attached else {
      return .failure(.notAttached)
    }
    guard let columns = message.cols?.value, let rows = message.rows?.value else {
      return .failure(.invalidSize)
    }
    let columnRange = RemoteTabNewGrid.columnRange
    let rowRange = RemoteTabNewGrid.rowRange
    return .success(
      Self(
        contentID: attached,
        columns: min(max(columns, columnRange.lowerBound), columnRange.upperBound),
        rows: min(max(rows, rowRange.lowerBound), rowRange.upperBound)))
  }
}

/// One try at applying a `resize` to a terminal (`RemoteSnapshotSource.resizeGrid`).
nonisolated enum RemoteResizeAttempt: Equatable, Sendable {
  /// The grid changes to the requested size; the PTY follows asynchronously.
  case applied
  /// The grid already has the requested size.
  case unchanged
  /// The surface exists but its cell metrics do not yet; try again.
  case notReady
  /// No live surface (never started since launch, or hibernated); wake it first.
  case noSurface
  /// No live surface, and the last start of the session failed.
  case failedToStart
}

/// How the app side of a valid `resize` ended: the grid changed, already had
/// that size, or the size cannot be applied (the requester gets an `error`
/// with `code` `resize_failed`). The reply then follows the session PTY
/// (`RemoteResizeConfirmation`).
nonisolated enum RemoteResizeResult: Equatable, Sendable {
  case applied
  case unchanged
  case failed(Failure)

  /// The `code` of the `error` a failed `resize` gets.
  static let errorCode = "resize_failed"

  nonisolated enum Failure: Error, Equatable, Sendable {
    /// No worktree lists the content any more.
    case contentGone
    /// The terminal had no live surface and could not be started.
    case wakeFailed
    /// The surface did not report cell metrics within `RemoteHostRouter.resizeReadyTimeout`.
    case notReady
    /// The app's grid changed but the session PTY kept another size.
    case sessionKeptItsSize
    /// The session PTY's size could not be read.
    case sizeUnreadable

    /// The `message` of the `error` frame.
    var message: String {
      switch self {
      case .contentGone: "the terminal is gone"
      case .wakeFailed: "the terminal did not start on the Mac"
      case .notReady: "the terminal was not ready on the Mac in time"
      case .sessionKeptItsSize: "the terminal session did not take the new size"
      case .sizeUnreadable: "could not read the terminal session's size"
      }
    }
  }
}

/// Whether the session PTY took a `resize`'s grid (`RemoteHostRouter.confirmResize`).
nonisolated enum RemoteResizeConfirmation: Equatable, Sendable {
  case matched
  /// The PTY has another size: the last one read.
  case mismatch(columns: Int, rows: Int)
  /// No read of the PTY size succeeded.
  case unreadable
}

/// The `resize` in flight per terminal, so a newer request of the same
/// terminal from any phone cancels an older one before it is applied (an older
/// wait's retry would otherwise put its size back over the newer one).
nonisolated struct RemoteResizeWaits {
  private struct Wait {
    let connID: String
    let token: UUID
    let task: Task<Void, Never>
  }

  private var byContent: [UUID: Wait] = [:]

  /// Records `task` as the wait for `contentID`, cancelling the one it replaces.
  mutating func start(contentID: UUID, connID: String, token: UUID, task: Task<Void, Never>) {
    cancel(contentID: contentID)
    byContent[contentID] = Wait(connID: connID, token: token, task: task)
  }

  /// Cancels the wait for `contentID`, whichever phone asked for it.
  mutating func cancel(contentID: UUID) {
    byContent.removeValue(forKey: contentID)?.task.cancel()
  }

  /// Cancels the waits `connID` asked for (it detached or left).
  mutating func cancel(connID: String) {
    for (contentID, wait) in byContent where wait.connID == connID {
      wait.task.cancel()
      byContent[contentID] = nil
    }
  }

  /// Forgets a finished wait, unless a newer one replaced it.
  mutating func finished(contentID: UUID, token: UUID) {
    guard byContent[contentID]?.token == token else { return }
    byContent[contentID] = nil
  }

  /// The phone whose wait for `contentID` is in flight.
  func pendingConnID(contentID: UUID) -> String? {
    byContent[contentID]?.connID
  }
}

// MARK: - Outbound payloads

nonisolated struct RemoteHelloMessage: Encodable, Equatable, Sendable {
  var t = "hello"
  var v = 1
  /// The host name (ИД4): the configured name or the computer name.
  let host: String
  /// This Mac's relay id (ИД1); omitted when it has none.
  var hostId: String?
  /// Where a phone on the Mac's network can try the LAN shortcut; omitted otherwise.
  var lan: RemoteLANCandidate?
}

/// The host → relay rename control frame's body (ИД3), sent on `controlConnID`.
nonisolated struct RemoteHostNameMessage: Encodable, Equatable, Sendable {
  var t = "host.name"
  /// Omitted when the name normalizes to nothing.
  var name: String?
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
  /// A machine-readable reason (e.g. `resize_failed`); omitted when none.
  var code: String?
  /// The terminal the error is about, for messages without an `id` (`resize`); omitted when none.
  var contentId: String?

  // Encode `id` as an explicit null so clients can match on it.
  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(t, forKey: .t)
    try container.encode(id, forKey: .id)
    try container.encode(message, forKey: .message)
    try container.encodeIfPresent(code, forKey: .code)
    try container.encodeIfPresent(contentId, forKey: .contentId)
  }

  private enum CodingKeys: String, CodingKey {
    case t, id, message, code, contentId
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
