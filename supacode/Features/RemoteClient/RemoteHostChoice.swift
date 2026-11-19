import Foundation

/// What the client does with the relay's host list (docs/remote-access-protocol.md, "Relay message").
///
/// A saved selection never changes by itself: when the saved Mac is gone from the list the user
/// chooses. The client picks alone only when nothing is saved and exactly one other Mac is online;
/// otherwise it would have to guess. This Mac's own id never counts and is never pickable.
/// Port of `supacode-remote/.../relay/HostChoice.kt`.
nonisolated enum RemoteHostChoice {
  enum Decision: Equatable, Sendable {
    /// Nothing to do: an old relay, or the saved Mac is in the list.
    case none
    /// Bind the connection to this Mac and save it.
    case select(String)
    /// Open the Mac picker.
    case askUser
  }

  /// `hosts` nil: an old relay (single host) → `.none`. This Mac (`ownHostID`) never counts.
  static func decide(saved: String?, hosts: [RemoteClientHostInfo]?, ownHostID: String?) -> Decision {
    guard let hosts else { return .none }
    let others = pickable(hosts, ownHostID: ownHostID)
    if let saved {
      return others.contains { $0.id == saved } ? .none : .askUser
    }
    let online = others.filter(\.online)
    if online.count == 1, let only = online.first { return .select(only.id) }
    return .askUser
  }

  /// The picker's rows: every host except this Mac.
  static func pickable(_ hosts: [RemoteClientHostInfo], ownHostID: String?) -> [RemoteClientHostInfo] {
    hosts.filter { $0.id != ownHostID }
  }
}
