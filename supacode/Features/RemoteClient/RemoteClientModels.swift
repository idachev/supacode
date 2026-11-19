import Foundation
import SupacodeSettingsShared

// The short names (`v`, `fp`, `t`) are the wire protocol's field names.
// swiftlint:disable identifier_name

// The client's view of the wire protocol (docs/remote-access-protocol.md). Every model decodes
// tolerantly: a missing or `null` field takes its default and an unknown string stays a string,
// so a newer host never breaks an older client. A missing `id` on an identified type throws, and
// an element of a list array that throws is skipped (logged), never the whole frame. A field that
// is not of its type at all (a list that is not an array) still makes the frame unreadable. A
// `layout` stays whole or is dropped: half of one would draw panes that do not exist.

nonisolated private let modelsLogger = SupaLogger("RemoteClient")

nonisolated struct RemoteClientHostInfo: Decodable, Equatable, Sendable, Identifiable {
  let id: String
  var name: String?
  var online = false
}

nonisolated struct RemoteClientAgent: Decodable, Equatable, Sendable {
  var agent = ""
  var activity = ""
}

nonisolated struct RemoteClientTab: Decodable, Equatable, Sendable, Identifiable {
  let id: String
  var contentId = ""
  var title = ""
  var focused = false
  var working = false
  var readOnly = false
  var agents: [RemoteClientAgent] = []
}

nonisolated indirect enum RemoteClientLayoutNode: Decodable, Equatable, Sendable {
  case pane(String)
  case split(direction: String, ratio: Double, left: RemoteClientLayoutNode, right: RemoteClientLayoutNode)
}

nonisolated struct RemoteClientLayoutGroup: Decodable, Equatable, Sendable, Identifiable {
  let id: String
  var focusedPaneId: String?
  var zoomedPaneId: String?
  let tree: RemoteClientLayoutNode
}

nonisolated struct RemoteClientLayoutPane: Decodable, Equatable, Sendable, Identifiable {
  let id: String
  var tabIds: [String] = []
  var selectedTabId: String?
}

nonisolated struct RemoteClientLayout: Decodable, Equatable, Sendable {
  var mode = "tabsPerSplit"
  var activeGroupId = ""
  var groups: [RemoteClientLayoutGroup] = []
  var panes: [RemoteClientLayoutPane] = []
}

nonisolated struct RemoteClientWorktree: Decodable, Equatable, Sendable, Identifiable {
  let id: String
  var name = ""
  var branch = ""
  var status = ""
  var focused = false
  var title: String?
  var working = false
  var canDeleteWorktree = false
  var tabs: [RemoteClientTab] = []
  var layout: RemoteClientLayout?
}

nonisolated struct RemoteClientRepository: Decodable, Equatable, Sendable, Identifiable {
  let id: String
  var name = ""
  var group: String?
  var canCreateWorktree = false
  var worktrees: [RemoteClientWorktree] = []
  var rowIds: [String] = []
}

nonisolated struct RemoteClientSection: Decodable, Equatable, Sendable {
  var kind = ""
  var title: String?
  var collapsed: Bool?
  var worktreeIds: [String]?
  var repositoryIds: [String]?
  var repositoryId: String?
}

nonisolated struct RemoteClientLoadFailure: Decodable, Equatable, Sendable {
  var repositoryId = ""
  var message = ""
}

nonisolated struct RemoteClientList: Decodable, Equatable, Sendable {
  var id: Int?
  var repos: [RemoteClientRepository] = []
  var sections: [RemoteClientSection] = []
  var canRefreshWorktrees = false
  var loadFailures: [RemoteClientLoadFailure] = []
}

nonisolated struct RemoteClientLAN: Decodable, Equatable, Sendable {
  var addrs: [String] = []
  var port = 0
  var fp = ""
  var fpMac = ""
}

nonisolated struct RemoteClientHello: Decodable, Equatable, Sendable {
  var v = 0
  var host: String?
  var hostId: String?
  var lan: RemoteClientLAN?
  var app: String?
  var caps: [String] = []
}

nonisolated struct RemoteClientRelayStatus: Decodable, Equatable, Sendable {
  var hostOnline = false
  var host: String?
  /// nil: an old relay without multi-host support (an empty array is a new relay with no host yet).
  var hosts: [RemoteClientHostInfo]?
}

// MARK: - Decoding

private nonisolated extension KeyedDecodingContainer {
  /// The value of `key`, or `fallback` when it is missing or `null`.
  func value<T: Decodable>(_ key: Key, or fallback: T) throws -> T {
    try decodeIfPresent(T.self, forKey: key) ?? fallback
  }

  /// The elements of the array at `key` that decode, in order; `[]` when it is missing or `null`.
  /// A value that is not an array still throws.
  func elements<T: Decodable>(_ key: Key) throws -> [T] {
    try elementsIfPresent(key) ?? []
  }

  /// As `elements`, but nil when the key is missing or `null`.
  func elementsIfPresent<T: Decodable>(_ key: Key) throws -> [T]? {
    guard contains(key), try !decodeNil(forKey: key) else { return nil }
    var items = try nestedUnkeyedContainer(forKey: key)
    var result: [T] = []
    while !items.isAtEnd {
      let index = items.currentIndex
      do {
        result.append(try items.decode(T.self))
      } catch {
        // Field names and the index only: never a value.
        let path = RemoteClientFrame.Unreadable.path(items.codingPath)
        modelsLogger.warning("Remote client skipped a list element it cannot read: \(path)[\(index)]")
        // A failed decode may leave the element unread; step over it.
        if items.currentIndex == index { _ = try? items.decode(SkippedElement.self) }
        guard items.currentIndex > index else { break }
      }
    }
    return result
  }
}

/// Decodes any JSON value without reading it: steps over a list element that did not decode.
private nonisolated struct SkippedElement: Decodable {
  init(from decoder: Decoder) throws {}
}

nonisolated extension RemoteClientHostInfo {
  private enum CodingKeys: String, CodingKey { case id, name, online }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decodeIfPresent(String.self, forKey: .name)
    online = try c.value(.online, or: false)
  }
}

nonisolated extension RemoteClientAgent {
  private enum CodingKeys: String, CodingKey { case agent, activity }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    agent = try c.value(.agent, or: "")
    activity = try c.value(.activity, or: "")
  }
}

nonisolated extension RemoteClientTab {
  private enum CodingKeys: String, CodingKey { case id, contentId, title, focused, working, readOnly, agents }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    contentId = try c.value(.contentId, or: "")
    title = try c.value(.title, or: "")
    focused = try c.value(.focused, or: false)
    working = try c.value(.working, or: false)
    readOnly = try c.value(.readOnly, or: false)
    agents = try c.elements(.agents)
  }
}

nonisolated extension RemoteClientLayoutNode {
  private enum CodingKeys: String, CodingKey { case pane, split }
  private enum SplitKeys: String, CodingKey { case direction, ratio, left, right }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    if let pane = try c.decodeIfPresent(String.self, forKey: .pane) {
      self = .pane(pane)
      return
    }
    guard c.contains(.split) else {
      throw DecodingError.dataCorruptedError(
        forKey: .split, in: c, debugDescription: "a layout node is a pane or a split")
    }
    let s = try c.nestedContainer(keyedBy: SplitKeys.self, forKey: .split)
    self = .split(
      direction: try s.value(.direction, or: "horizontal"),
      ratio: try s.value(.ratio, or: 0.5),
      left: try s.decode(RemoteClientLayoutNode.self, forKey: .left),
      right: try s.decode(RemoteClientLayoutNode.self, forKey: .right))
  }
}

nonisolated extension RemoteClientLayoutGroup {
  private enum CodingKeys: String, CodingKey { case id, focusedPaneId, zoomedPaneId, tree }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    focusedPaneId = try c.decodeIfPresent(String.self, forKey: .focusedPaneId)
    zoomedPaneId = try c.decodeIfPresent(String.self, forKey: .zoomedPaneId)
    tree = try c.decode(RemoteClientLayoutNode.self, forKey: .tree)
  }
}

nonisolated extension RemoteClientLayoutPane {
  private enum CodingKeys: String, CodingKey { case id, tabIds, selectedTabId }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    tabIds = try c.value(.tabIds, or: [])
    selectedTabId = try c.decodeIfPresent(String.self, forKey: .selectedTabId)
  }
}

nonisolated extension RemoteClientLayout {
  private enum CodingKeys: String, CodingKey { case mode, activeGroupId, groups, panes }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    mode = try c.value(.mode, or: "tabsPerSplit")
    activeGroupId = try c.value(.activeGroupId, or: "")
    groups = try c.value(.groups, or: [])
    panes = try c.value(.panes, or: [])
  }
}

nonisolated extension RemoteClientWorktree {
  private enum CodingKeys: String, CodingKey {
    case id, name, branch, status, focused, title, working, canDeleteWorktree, tabs, layout
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.value(.name, or: "")
    branch = try c.value(.branch, or: "")
    status = try c.value(.status, or: "")
    focused = try c.value(.focused, or: false)
    title = try c.decodeIfPresent(String.self, forKey: .title)
    working = try c.value(.working, or: false)
    canDeleteWorktree = try c.value(.canDeleteWorktree, or: false)
    tabs = try c.elements(.tabs)
    // A layout this client cannot read must not hide the worktree and its tabs.
    layout = (try? c.decodeIfPresent(RemoteClientLayout.self, forKey: .layout)) ?? nil
  }
}

nonisolated extension RemoteClientRepository {
  private enum CodingKeys: String, CodingKey { case id, name, group, canCreateWorktree, worktrees, rowIds }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.value(.name, or: "")
    group = try c.decodeIfPresent(String.self, forKey: .group)
    canCreateWorktree = try c.value(.canCreateWorktree, or: false)
    worktrees = try c.elements(.worktrees)
    rowIds = try c.elements(.rowIds)
  }
}

nonisolated extension RemoteClientSection {
  private enum CodingKeys: String, CodingKey {
    case kind, title, collapsed, worktreeIds, repositoryIds, repositoryId
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    kind = try c.value(.kind, or: "")
    title = try c.decodeIfPresent(String.self, forKey: .title)
    collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed)
    worktreeIds = try c.elementsIfPresent(.worktreeIds)
    repositoryIds = try c.elementsIfPresent(.repositoryIds)
    repositoryId = try c.decodeIfPresent(String.self, forKey: .repositoryId)
  }
}

nonisolated extension RemoteClientLoadFailure {
  private enum CodingKeys: String, CodingKey { case repositoryId, message }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    repositoryId = try c.value(.repositoryId, or: "")
    message = try c.value(.message, or: "")
  }
}

nonisolated extension RemoteClientList {
  private enum CodingKeys: String, CodingKey { case id, repos, sections, canRefreshWorktrees, loadFailures }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(Int.self, forKey: .id)
    repos = try c.elements(.repos)
    sections = try c.elements(.sections)
    canRefreshWorktrees = try c.value(.canRefreshWorktrees, or: false)
    loadFailures = try c.elements(.loadFailures)
  }
}

nonisolated extension RemoteClientLAN {
  private enum CodingKeys: String, CodingKey { case addrs, port, fp, fpMac }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    addrs = try c.elements(.addrs)
    port = try c.value(.port, or: 0)
    fp = try c.value(.fp, or: "")
    fpMac = try c.value(.fpMac, or: "")
  }
}

nonisolated extension RemoteClientHello {
  private enum CodingKeys: String, CodingKey { case v, host, hostId, lan, app, caps }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    v = try c.value(.v, or: 0)
    host = try c.decodeIfPresent(String.self, forKey: .host)
    hostId = try c.decodeIfPresent(String.self, forKey: .hostId)
    lan = try c.decodeIfPresent(RemoteClientLAN.self, forKey: .lan)
    app = try c.decodeIfPresent(String.self, forKey: .app)
    caps = try c.elements(.caps)
  }
}

nonisolated extension RemoteClientRelayStatus {
  private enum CodingKeys: String, CodingKey { case hostOnline, host, hosts }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    hostOnline = try c.value(.hostOnline, or: false)
    host = try c.decodeIfPresent(String.self, forKey: .host)
    hosts = try c.elementsIfPresent(.hosts)
  }
}

// MARK: - Frames

/// One decoded frame from the host or the relay.
nonisolated enum RemoteClientFrame: Equatable, Sendable {
  case relay(RemoteClientRelayStatus)
  case hello(RemoteClientHello)
  case list(RemoteClientList)
  case attached(id: Int?, contentId: String, cols: Int, rows: Int)
  case out(contentId: String, bytes: [UInt8])
  case size(contentId: String, cols: Int, rows: Int)
  case detached(contentId: String, reason: String)
  case error(id: Int?, message: String, code: String?, contentId: String?)
  /// Any other reply with a `t` (tab.new, pane.split, watch, worktree.new, …): its string,
  /// integer and boolean fields as text; objects, arrays and `null` are skipped.
  case reply(t: String, id: Int?, fields: [String: String])

  /// nil: whatever `read` refuses (not JSON, not an object, no string `t`, the bare text `pong`,
  /// a frame of a type this client reads that does not decode).
  static func decode(_ text: String) -> RemoteClientFrame? {
    try? read(text).get()
  }

  /// The frame, or why the text is none (`Unreadable`, safe to log).
  static func read(_ text: String) -> Result<RemoteClientFrame, Unreadable> {
    let data = Data(text.utf8)
    let decoder = JSONDecoder()
    guard let top = try? decoder.decode([String: Scalar].self, from: data) else {
      return .failure(Unreadable(type: nil, reason: "not a JSON object"))
    }
    guard case .string(let type)? = top["t"] else { return .failure(Unreadable(type: nil, reason: "no string t")) }
    switch type {
    case "relay": return body(RemoteClientRelayStatus.self, type, data).map(Self.relay)
    case "hello": return body(RemoteClientHello.self, type, data).map(Self.hello)
    case "list": return body(RemoteClientList.self, type, data).map(Self.list)
    case "attached":
      return .success(
        .attached(
          id: top["id"]?.int, contentId: top["contentId"]?.string ?? "",
          cols: top["cols"]?.int ?? 0, rows: top["rows"]?.int ?? 0))
    case "out":
      guard let encoded = top["b64"]?.string, let bytes = Data(base64Encoded: encoded) else {
        return .failure(Unreadable(type: type, reason: "b64 is not base64"))
      }
      return .success(.out(contentId: top["contentId"]?.string ?? "", bytes: [UInt8](bytes)))
    case "size":
      return .success(
        .size(contentId: top["contentId"]?.string ?? "", cols: top["cols"]?.int ?? 0, rows: top["rows"]?.int ?? 0))
    case "detached":
      return .success(.detached(contentId: top["contentId"]?.string ?? "", reason: top["reason"]?.string ?? ""))
    case "error":
      return .success(
        .error(
          id: top["id"]?.int, message: top["message"]?.string ?? "", code: top["code"]?.string,
          contentId: top["contentId"]?.string))
    default:
      var fields: [String: String] = [:]
      for (key, value) in top where key != "t" && key != "id" {
        if let text = value.text { fields[key] = text }
      }
      return .success(.reply(t: type, id: top["id"]?.int, fields: fields))
    }
  }

  /// Why a text is no frame, for the log. Holds no value of the frame: `type` is set only for the
  /// frame types this client reads (never a string the host made up), and `reason` names a decoding
  /// failure by its kind and coding path (field names and array indices).
  struct Unreadable: Error, Equatable, Sendable {
    let type: String?
    let reason: String

    /// `kind at path`, e.g. `typeMismatch at repos[0].worktrees`.
    static func reason(_ error: any Error) -> String {
      guard let error = error as? DecodingError else { return "not a decoding error" }
      switch error {
      case .typeMismatch(_, let context): return "typeMismatch at \(path(context.codingPath))"
      case .valueNotFound(_, let context): return "valueNotFound at \(path(context.codingPath))"
      case .keyNotFound(let key, let context):
        return "keyNotFound \(key.stringValue) at \(path(context.codingPath))"
      case .dataCorrupted(let context): return "dataCorrupted at \(path(context.codingPath))"
      @unknown default: return "unknown decoding error"
      }
    }

    /// `repos[0].worktrees`; `top` for the frame itself.
    static func path(_ codingPath: [any CodingKey]) -> String {
      var text = ""
      for key in codingPath {
        if let index = key.intValue {
          text += "[\(index)]"
        } else {
          text += text.isEmpty ? key.stringValue : ".\(key.stringValue)"
        }
      }
      return text.isEmpty ? "top" : text
    }
  }

  private static func body<T: Decodable>(_: T.Type, _ type: String, _ data: Data) -> Result<T, Unreadable> {
    do {
      return .success(try JSONDecoder().decode(T.self, from: data))
    } catch {
      return .failure(Unreadable(type: type, reason: Unreadable.reason(error)))
    }
  }

  /// One top-level value of a frame; objects, arrays, `null` and fractions are `.other`.
  private enum Scalar: Decodable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case other

    init(from decoder: Decoder) throws {
      let c = try decoder.singleValueContainer()
      if let value = try? c.decode(String.self) {
        self = .string(value)
      } else if let value = try? c.decode(Bool.self) {
        self = .bool(value)
      } else if let value = try? c.decode(Int.self) {
        self = .int(value)
      } else {
        self = .other
      }
    }

    var string: String? {
      if case .string(let value) = self { value } else { nil }
    }

    var int: Int? {
      if case .int(let value) = self { value } else { nil }
    }

    var text: String? {
      switch self {
      case .string(let value): value
      case .int(let value): String(value)
      case .bool(let value): String(value)
      case .other: nil
      }
    }
  }
}

// swiftlint:enable identifier_name
