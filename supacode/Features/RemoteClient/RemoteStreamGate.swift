import Foundation

/// The path a remote frame arrived on: the relay WebSocket or the pinned LAN WebSocket.
nonisolated enum RemoteClientPath: Hashable, Sendable { case relay, lan }

/// Which path carries ONE terminal's stream. One gate per attached content.
///
/// The host holds one `attach` per connection, so during a path switch both paths stream for a
/// moment. Only the stream of `current` reaches the screen. A new `attach` on another path does
/// not switch at once: the old stream keeps running until the `attached` of the new one arrives
/// (it carries the screen anew); only then the path changes and the old attaches are stopped with
/// a `detach`. Frames from a path that is no longer `current` (late ones, from a dropped
/// connection, from an old attach) are discarded.
/// Port of `supacode-remote/web/src/stream-gate.mjs`, for one content.
nonisolated struct RemoteStreamGate: Sendable {
  enum Kind: Sendable { case attached(id: Int?), out, size, detached }

  struct Verdict: Equatable, Sendable {
    var deliver: Bool
    var detach: [RemoteClientPath]
  }

  /// The path whose `attached` answered, and so the only one whose frames are delivered.
  private(set) var current: RemoteClientPath?
  private var pending: (path: RemoteClientPath, id: Int)?
  /// The paths on which the host holds an attach of ours, in the order they were sent.
  private var attachedOn: [RemoteClientPath] = []

  /// An `attach` with this request id left on `path`. Call before its reply can arrive.
  mutating func attachSent(on path: RemoteClientPath, id: Int) {
    pending = (path, id)
    if !attachedOn.contains(path) { attachedOn.append(path) }
  }

  /// A `detach` left on `path`: the stream stops; returns the other paths that still hold an attach.
  mutating func detachSent(on path: RemoteClientPath) -> [RemoteClientPath] {
    pending = nil
    current = nil
    attachedOn.removeAll { $0 == path }
    return takeOthers(except: nil)
  }

  /// The path's socket closed: the host forgot the attach there, its frames are no longer accepted.
  mutating func closed(_ path: RemoteClientPath) {
    attachedOn.removeAll { $0 == path }
    if current == path { current = nil }
    if pending?.path == path { pending = nil }
  }

  /// Whether the frame reaches the terminal, and on which paths a `detach` must go out now.
  mutating func accept(from path: RemoteClientPath, _ kind: Kind) -> Verdict {
    if case .attached(let id) = kind, answersPending(path: path, id: id) {
      current = path
      pending = nil
      return Verdict(deliver: true, detach: takeOthers(except: path))
    }
    guard path == current else { return Verdict(deliver: false, detach: []) }
    if case .detached = kind { attachedOn.removeAll { $0 == path } }
    return Verdict(deliver: true, detach: [])
  }

  /// An `attached` answers the waiting attach on the same path, with the same id when it carries one.
  private func answersPending(path: RemoteClientPath, id: Int?) -> Bool {
    guard let pending, pending.path == path else { return false }
    return id == nil || id == pending.id
  }

  /// Forgets and returns every attached path except `path`.
  private mutating func takeOthers(except path: RemoteClientPath?) -> [RemoteClientPath] {
    let others = attachedOn.filter { $0 != path }
    attachedOn.removeAll { $0 != path }
    return others
  }
}
