import Foundation

/// When the client asks the host for a new size (ТР8).
///
/// The local grid always shows the remote grid (ТР7); this decides when the client asks the host to
/// make the remote grid the one that fits the local pane: after its own `attached`, and when the
/// pane's fitting grid changed and then held for `settle`. A `size` from the host is never a reason
/// to ask (the protocol's client rule), so a refused or clamped resize, or another client that took
/// the size, is not fought over until the local pane changes again (ТР8а).
nonisolated struct RemoteAutoResize: Sendable {
  static let settle: Duration = .milliseconds(200)

  struct Grid: Equatable, Sendable {
    let columns: Int
    let rows: Int
  }

  enum Step: Equatable, Sendable {
    case nothing
    case schedule
    case send(Grid)
  }

  /// The pane's last measured fitting grid.
  private var measured: Grid?
  /// The grid of the last `attached` or `size`.
  private var remote: Grid?
  private var isAttached = false
  /// A measurement that was neither sent nor attached with yet.
  private var unsent = false

  /// The pane's fitting grid was measured (a layout pass). `.schedule`: start or restart the 200 ms timer.
  mutating func paneMeasured(_ grid: Grid) -> Step {
    guard grid != measured else { return .nothing }
    measured = grid
    unsent = true
    return .schedule
  }

  /// The 200 ms passed with no newer measurement.
  mutating func settled() -> Step {
    guard isAttached, unsent, let measured else { return .nothing }
    unsent = false
    return measured == remote ? .nothing : .send(measured)
  }

  /// An `attached` arrived with the remote grid.
  mutating func attached(remote grid: Grid) -> Step {
    remote = grid
    isAttached = true
    unsent = false
    guard let measured, measured != grid else { return .nothing }
    return .send(measured)
  }

  /// A `size` arrived. Never a reason to send.
  mutating func sizeReceived(_ grid: Grid) {
    remote = grid
  }
}

/// The bytes the client writes to the local terminal around the stream.
nonisolated enum RemoteTerminalBytes {
  /// CSI 3 J, CSI 2 J, CSI H — before the redraw of a new `attached` (ТР6).
  static let clearForRedraw: [UInt8] = Array("\u{1b}[3J\u{1b}[2J\u{1b}[H".utf8)
}
