import Foundation

/// What a remote window says while there is no live connection (БН1–БН3): one line above each
/// remote terminal, and the same line under the window title. Plain values, so every state of
/// the table is testable without a view.
nonisolated enum RemoteConnectionBanner {
  enum Kind: Equatable, Sendable {
    /// The link is up or coming up; the terminal has not been redrawn yet.
    case connecting
    /// The Mac is not on the relay.
    case hostOffline
    /// Typing goes nowhere.
    case noConnection
  }

  /// The banner of a terminal, nil while it is live.
  ///
  /// - `isAttached`: the terminal's stream got `attached` since the link last came up.
  /// - `wasAttached`: it got `attached` at some point of this connection, so a link that is
  ///   `.connecting` now is a lost one (and not the first connect).
  static func kind(status: RemoteClientStatus, isAttached: Bool, wasAttached: Bool) -> Kind? {
    switch status {
    case .online:
      isAttached ? nil : .connecting
    case .connecting:
      wasAttached ? .noConnection : .connecting
    case .hostOffline:
      .hostOffline
    case .failed, .idle, .choosingHost, .unsupportedHost:
      .noConnection
    }
  }

  /// The banner text; `<Mac>` is the host name, or "the Mac" without one.
  static func text(
    status: RemoteClientStatus, isAttached: Bool, wasAttached: Bool, hostName: String?
  ) -> String? {
    guard let kind = kind(status: status, isAttached: isAttached, wasAttached: wasAttached) else {
      return nil
    }
    let mac = hostName.flatMap { $0.isEmpty ? nil : $0 } ?? "the Mac"
    return switch kind {
    case .connecting: "Connecting to \(mac)…"
    case .hostOffline: "\(mac) is offline."
    case .noConnection: "No connection to \(mac). Typing is not sent."
    }
  }
}
