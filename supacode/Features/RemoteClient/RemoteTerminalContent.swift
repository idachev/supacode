import AppKit
import Foundation
import GhosttyKit
import Observation
import SupacodeSettingsShared

nonisolated private let remoteTerminalLogger = SupaLogger("RemoteTerminal")

/// What a remote tab does with each event, as plain values (ТР4–ТР9): the content runs the effects
/// against the pipe, the surface and the connection, so the order of those calls is testable
/// without any of them.
nonisolated struct RemoteTerminalDriver: Sendable {
  typealias Grid = RemoteAutoResize.Grid

  enum Phase: Equatable, Sendable {
    case starting
    case live
    case ended(reason: String)
  }

  enum Effect: Equatable, Sendable {
    /// `connection.attach`, and consume its events.
    case attach
    /// Bytes for the local terminal, through the pipe.
    case writePipe([UInt8])
    /// The local grid is the remote grid (ТР7).
    case pin(Grid)
    /// Ask the host for this grid (`resize` with `hold:true`).
    case wantGrid(Grid)
    /// Start or restart the settle timer.
    case scheduleSettle
    /// Typing for the remote terminal.
    case sendInput([UInt8])
    /// `connection.detach`, and stop the settle timer.
    case detach
  }

  /// The reason a pipe that closed under a live tab ends it.
  static let pipeClosedReason = "The local terminal closed"

  private(set) var phase = Phase.starting
  private(set) var remoteGrid: Grid?
  private var autoResize = RemoteAutoResize()
  private var filter = RemoteQueryFilter()
  private var pipeOpen = false

  private var hasEnded: Bool {
    if case .ended = phase { true } else { false }
  }

  /// The surface's `remote-pipe` connected: attach now, so no `out` arrives before the pipe can take it.
  mutating func pipeOpened() -> [Effect] {
    guard !pipeOpen, !hasEnded else { return [] }
    pipeOpen = true
    return [.attach]
  }

  /// Typing from the local terminal. Dropped once the tab ended (the connection would still send it).
  mutating func pipeInput(_ bytes: [UInt8]) -> [Effect] {
    guard pipeOpen, !hasEnded, !bytes.isEmpty else { return [] }
    return [.sendInput(bytes)]
  }

  /// The pipe closed: the surface's process is gone, so nothing can show the terminal any more.
  mutating func pipeClosed() -> [Effect] {
    guard pipeOpen, !hasEnded else { return [] }
    pipeOpen = false
    phase = .ended(reason: Self.pipeClosedReason)
    return [.detach]
  }

  mutating func event(_ event: RemoteTerminalEvent) -> [Effect] {
    guard !hasEnded else { return [] }
    switch event {
    case .attached(let columns, let rows):
      let grid = Grid(columns: columns, rows: rows)
      // A new stream: a half sequence left from the old one must not swallow the redraw.
      filter = RemoteQueryFilter()
      remoteGrid = grid
      phase = .live
      var effects: [Effect] = [.writePipe(RemoteTerminalBytes.clearForRedraw), .pin(grid)]
      if case .send(let wanted) = autoResize.attached(remote: grid) { effects.append(.wantGrid(wanted)) }
      return effects
    case .out(let bytes):
      let filtered = filter.push(bytes)
      return filtered.isEmpty ? [] : [.writePipe(filtered)]
    case .size(let columns, let rows):
      let grid = Grid(columns: columns, rows: rows)
      remoteGrid = grid
      autoResize.sizeReceived(grid)
      return [.pin(grid)]
    case .detached(let reason):
      phase = .ended(reason: reason)
      return [.detach]
    }
  }

  /// A layout pass measured the grid that fits the local pane.
  mutating func paneMeasured(_ grid: Grid) -> [Effect] {
    guard !hasEnded else { return [] }
    return autoResize.paneMeasured(grid) == .schedule ? [.scheduleSettle] : []
  }

  /// The settle timer fired with no newer measurement.
  mutating func settled() -> [Effect] {
    guard !hasEnded, case .send(let grid) = autoResize.settled() else { return [] }
    return [.wantGrid(grid)]
  }
}

/// A tab whose terminal lives on another Mac (ТР1).
///
/// The tab is a normal Ghostty surface whose child is the bundled CLI's `supacode remote-pipe <id>`;
/// that process copies the surface's bytes to and from `RemotePipeServer`. The owner of the shared
/// pipe server routes its callbacks by content id to `pipeOpened()`, `pipeInput(_:)` and
/// `pipeClosed()` (the server has one callback of each kind for every content). Once the pipe opens
/// the content attaches through `RemoteClientConnection`, filters the remote output (ТР4), pins the
/// local grid to the remote one (ТР7) and asks the host for the pane's grid when it settles (ТР8).
///
/// Nothing about the tab is persisted: its snapshot is an ephemeral terminal, which the layout
/// store drops (`strippingEphemeralContent`).
@MainActor
@Observable
final class RemoteTerminalContent: TabContent {
  typealias Phase = RemoteTerminalDriver.Phase

  /// Scrollback lines the host replays on `attach`.
  nonisolated static let scrollback = 2000

  let id: ContentID
  let kind: ContentKind = .terminal
  let remoteContentID: String
  let title: String
  private(set) var phase: Phase = .starting
  private(set) var remoteGrid: RemoteAutoResize.Grid?
  private(set) var sessionFailedToStart = false
  private var surfaceView: GhosttySurfaceView?

  @ObservationIgnored private let connection: RemoteClientConnection
  @ObservationIgnored private let pipes: RemotePipeServer
  @ObservationIgnored private let runtime: GhosttyRuntime
  @ObservationIgnored private let clock: any Clock<Duration>
  @ObservationIgnored private var driver = RemoteTerminalDriver()
  @ObservationIgnored private var events: Task<Void, Never>?
  @ObservationIgnored private var settleTimer: Task<Void, Never>?
  @ObservationIgnored private var isTornDown = false

  init(
    remoteContentID: String,
    title: String,
    connection: RemoteClientConnection,
    pipes: RemotePipeServer,
    runtime: GhosttyRuntime,
    clock: any Clock<Duration>,
    id: ContentID = ContentID()
  ) {
    self.id = id
    self.remoteContentID = remoteContentID
    self.title = title
    self.connection = connection
    self.pipes = pipes
    self.runtime = runtime
    self.clock = clock
  }

  nonisolated deinit {}

  var renderer: NSView? { surfaceView }

  /// Starts the surface whose child is `supacode remote-pipe <id>`, with no zmx, no command
  /// wrapper and no shell integration. A second call while the surface lives does nothing.
  func startSession(at geometry: ContentGeometry) {
    guard surfaceView == nil, !isTornDown else { return }
    guard let command = Self.pipeCommand(remoteContentID: remoteContentID) else {
      remoteTerminalLogger.warning("Remote tab not started: no pipe command")
      sessionFailedToStart = true
      return
    }
    let token = pipes.expect(contentID: remoteContentID)
    let view = GhosttySurfaceView(
      id: id.rawValue,
      runtime: runtime,
      workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
      command: command,
      environmentVariables: [
        RemotePipeProtocol.socketVariable: pipes.socketPath,
        RemotePipeProtocol.tokenVariable: token,
      ],
      commandWrapper: [],
      disableShellIntegration: true,
      initialGeometry: geometry,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
    guard view.surface != nil else {
      view.closeSurface()
      pipes.forget(contentID: remoteContentID)
      remoteTerminalLogger.warning("Remote tab not started: no Ghostty surface")
      sessionFailedToStart = true
      return
    }
    sessionFailedToStart = false
    view.onPaneGridMeasured = { [weak self] columns, rows in
      self?.paneMeasured(RemoteAutoResize.Grid(columns: columns, rows: rows))
    }
    surfaceView = view
  }

  /// The session lives on the other Mac and the pipe dies with the surface, so the renderer is never
  /// dropped on its own (`isHibernatable` is false).
  func hibernate() {}

  /// Detaches, forgets the pipe token (closing an open pipe), stops the timers and closes the
  /// surface. Safe to call more than once.
  func tearDown() {
    guard !isTornDown else { return }
    // First: `forget` reports the closing pipe back through `pipeClosed()` at once.
    isTornDown = true
    events?.cancel()
    events = nil
    settleTimer?.cancel()
    settleTimer = nil
    connection.detach(contentID: remoteContentID)
    pipes.forget(contentID: remoteContentID)
    surfaceView?.onPaneGridMeasured = nil
    surfaceView?.closeSurface()
    surfaceView = nil
  }

  /// A plain terminal snapshot that is never persisted: the launch marks it ephemeral.
  func snapshot() -> ContentSnapshot {
    Self.snapshot(id: id)
  }

  nonisolated static func snapshot(id: ContentID) -> ContentSnapshot {
    ContentSnapshot(
      id: id,
      state: .terminal(TerminalContentState(workingDirectory: nil, launch: LaunchOverride(bypassZmx: true)))
    )
  }

  // MARK: - Pipe events (routed by the pipe server's owner)

  func pipeOpened() {
    run(driver.pipeOpened())
  }

  func pipeInput(_ bytes: [UInt8]) {
    run(driver.pipeInput(bytes))
  }

  func pipeClosed() {
    run(driver.pipeClosed())
  }

  // MARK: - Effects

  private func paneMeasured(_ grid: RemoteAutoResize.Grid) {
    run(driver.paneMeasured(grid))
  }

  private func run(_ effects: [RemoteTerminalDriver.Effect]) {
    guard !isTornDown else { return }
    for effect in effects {
      switch effect {
      case .attach:
        consume(connection.attach(contentID: remoteContentID, scrollback: Self.scrollback))
      case .writePipe(let bytes):
        pipes.write(contentID: remoteContentID, bytes)
      case .pin(let grid):
        _ = surfaceView?.pinGrid(columns: grid.columns, rows: grid.rows)
      case .wantGrid(let grid):
        connection.setWantedGrid(contentID: remoteContentID, columns: grid.columns, rows: grid.rows)
      case .scheduleSettle:
        scheduleSettle()
      case .sendInput(let bytes):
        connection.sendInput(contentID: remoteContentID, bytes: bytes)
      case .detach:
        settleTimer?.cancel()
        settleTimer = nil
        connection.detach(contentID: remoteContentID)
      }
    }
    // Only real changes reach observers: `out` runs through here for every chunk.
    if phase != driver.phase { phase = driver.phase }
    if remoteGrid != driver.remoteGrid { remoteGrid = driver.remoteGrid }
  }

  private func consume(_ stream: AsyncStream<RemoteTerminalEvent>) {
    events?.cancel()
    events = Task { [weak self] in
      for await event in stream {
        guard let self else { return }
        self.run(self.driver.event(event))
      }
    }
  }

  private func scheduleSettle() {
    settleTimer?.cancel()
    let clock = self.clock
    settleTimer = Task { [weak self] in
      do { try await clock.sleep(for: RemoteAutoResize.settle) } catch { return }
      guard let self else { return }
      self.settleTimer = nil
      self.run(self.driver.settled())
    }
  }

  /// `'<app>/Contents/Resources/bin/supacode' remote-pipe '<id>'`, the CLI the app puts on `PATH`
  /// for its terminals. Nil without a resource directory, or for an id that is not one plain word
  /// (the id comes from the other Mac and lands in a shell command line).
  nonisolated static func pipeCommand(remoteContentID: String, resourceURL: URL? = Bundle.main.resourceURL) -> String? {
    guard isPlainWord(remoteContentID), let resourceURL else { return nil }
    let cli = resourceURL.appending(path: "bin/supacode", directoryHint: .notDirectory).path(percentEncoded: false)
    return "\(SSHCommand.loginShellQuote(cli)) remote-pipe \(SSHCommand.loginShellQuote(remoteContentID))"
  }

  /// Letters, digits, `-`, `_` and `.`, not starting with `-` (an option to the CLI's parser).
  nonisolated private static func isPlainWord(_ value: String) -> Bool {
    guard let first = value.unicodeScalars.first, first != "-" else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
      scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "-_.".unicodeScalars.contains(scalar))
    }
  }
}
