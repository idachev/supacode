import AppKit
import Foundation
import GhosttyKit
import Observation
import SupacodeSettingsShared
import SwiftUI

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
  /// The reason a stream that ended without `detached` ends the tab (the connection stopped or
  /// restarted, or another attach of the same id took the stream).
  static let streamEndedReason = "The connection to the Mac was reset"

  private(set) var phase = Phase.starting
  private(set) var remoteGrid: Grid?
  /// The stream got `attached` and the link has not dropped since: the terminal shows the host's
  /// screen as of the last redraw.
  private(set) var isAttached = false
  /// The stream got `attached` at some point (БН1): a `.connecting` link is then a lost one.
  private(set) var wasAttached = false
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

  /// Typing from the local terminal. Dropped, never queued, once the tab ended (the connection would
  /// still send it) and until the stream's own `attached` after the link came back (R23): the host's
  /// terminal must not get keys for a screen this tab has not redrawn.
  mutating func pipeInput(_ bytes: [UInt8]) -> [Effect] {
    guard pipeOpen, !hasEnded, isAttached, !bytes.isEmpty else { return [] }
    return [.sendInput(bytes)]
  }

  /// The pipe closed: the surface's process is gone, so nothing can show the terminal any more.
  mutating func pipeClosed() -> [Effect] {
    guard pipeOpen, !hasEnded else { return [] }
    pipeOpen = false
    phase = .ended(reason: Self.pipeClosedReason)
    return [.detach]
  }

  /// The event stream ended without `detached`. Nothing will reach the terminal again, so the tab
  /// ends and stops forwarding input. No `detach`: the connection already forgot the terminal, or
  /// another attach of the same id now owns it.
  mutating func streamEnded() -> [Effect] {
    guard !hasEnded else { return [] }
    phase = .ended(reason: Self.streamEndedReason)
    return []
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
      isAttached = true
      wasAttached = true
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

  /// The link to the Mac stopped being online: nothing reaches the terminal until the next
  /// `attached`. The tab stays; only the banner follows.
  mutating func linkLost() {
    isAttached = false
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
/// The tab is a normal Ghostty surface whose child is the bundled CLI's `supacode remote-pipe <key>`;
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

  /// Everything the content calls on the connection and the pipe server, so tests can stand in.
  struct Ports {
    var attach: @MainActor (_ contentID: String, _ scrollback: Int) -> AsyncStream<RemoteTerminalEvent>
    var detach: @MainActor (_ contentID: String) -> Void
    var sendInput: @MainActor (_ contentID: String, _ bytes: [UInt8]) -> Void
    var setWantedGrid: @MainActor (_ contentID: String, _ grid: RemoteAutoResize.Grid) -> Void
    var socketPath: String
    var expectPipe: @MainActor (_ contentID: String) -> String
    var forgetPipe: @MainActor (_ contentID: String) -> Void
    var writePipe: @MainActor (_ contentID: String, _ bytes: [UInt8]) -> Void
    /// The word the surface's `remote-pipe` names and its header carries: the content id under the
    /// session's prefix on the shared pipe server (`RemotePipeRouter`); the content id itself on a
    /// server of its own.
    var pipeKey: @MainActor (_ contentID: String) -> String = { $0 }

    static func live(connection: RemoteClientConnection, pipes: RemotePipeServer) -> Ports {
      Ports(
        attach: { connection.attach(contentID: $0, scrollback: $1) },
        detach: { connection.detach(contentID: $0) },
        sendInput: { connection.sendInput(contentID: $0, bytes: $1) },
        setWantedGrid: { connection.setWantedGrid(contentID: $0, columns: $1.columns, rows: $1.rows) },
        socketPath: pipes.socketPath,
        expectPipe: { pipes.expect(contentID: $0) },
        forgetPipe: { pipes.forget(contentID: $0) },
        writePipe: { pipes.write(contentID: $0, $1) }
      )
    }
  }

  /// Scrollback lines the host replays on `attach`.
  nonisolated static let scrollback = 2000

  let id: ContentID
  let kind: ContentKind = .terminal
  let remoteContentID: String
  let title: String
  private(set) var phase: Phase = .starting
  private(set) var remoteGrid: RemoteAutoResize.Grid?
  private(set) var sessionFailedToStart = false
  private(set) var isAttached = false
  private(set) var wasAttached = false
  /// The connection's status and the Mac's name, as the session last told this content (БН1).
  private(set) var status: RemoteClientStatus = .idle
  private(set) var hostName: String?
  /// The connection was online at some point since the session opened it (БН1). A content made while
  /// the link is down has never been attached, but its keys are dropped all the same.
  private(set) var seenOnline = false
  /// The grid that fits the local pane at this Mac's font, as the surface last measured it; nil
  /// before its first layout pass in a window. A new tab in this pane starts at it (`tab.new`).
  @ObservationIgnored private(set) var measuredGrid: RemoteAutoResize.Grid?
  private var surfaceView: GhosttySurfaceView?

  @ObservationIgnored private let ports: Ports
  @ObservationIgnored private let runtime: GhosttyRuntime
  @ObservationIgnored private let clock: any Clock<Duration>
  @ObservationIgnored private var driver = RemoteTerminalDriver()
  @ObservationIgnored private var events: Task<Void, Never>?
  @ObservationIgnored private var settleTimer: Task<Void, Never>?
  /// Which `scheduleSettle` the running timer belongs to; an older timer that wakes late does nothing.
  @ObservationIgnored private var settleGeneration = 0
  @ObservationIgnored private var isTornDown = false

  convenience init(
    remoteContentID: String,
    title: String,
    connection: RemoteClientConnection,
    pipes: RemotePipeServer,
    runtime: GhosttyRuntime,
    clock: any Clock<Duration>,
    id: ContentID = ContentID()
  ) {
    self.init(
      remoteContentID: remoteContentID, title: title, ports: .live(connection: connection, pipes: pipes),
      runtime: runtime, clock: clock, id: id)
  }

  init(
    remoteContentID: String,
    title: String,
    ports: Ports,
    runtime: GhosttyRuntime,
    clock: any Clock<Duration>,
    id: ContentID = ContentID()
  ) {
    self.id = id
    self.remoteContentID = remoteContentID
    self.title = title
    self.ports = ports
    self.runtime = runtime
    self.clock = clock
  }

  nonisolated deinit {}

  var renderer: NSView? { surfaceView }

  /// The banner over the terminal while there is no live connection (БН1); the content is its own
  /// toolbar, so what it shows reads the observed link state, and nothing is reserved when nil.
  var toolbar: (any TabContentToolbar)? { self }

  /// Starts the surface whose child is `supacode remote-pipe <key>`, with no zmx, no command
  /// wrapper and no shell integration. A second call while the surface lives does nothing.
  func startSession(at geometry: ContentGeometry) {
    guard surfaceView == nil, !isTornDown else { return }
    guard let command = Self.pipeCommand(pipeKey: ports.pipeKey(remoteContentID)) else {
      remoteTerminalLogger.warning("Remote tab not started: no pipe command")
      sessionFailedToStart = true
      return
    }
    let token = ports.expectPipe(remoteContentID)
    let view = GhosttySurfaceView(
      id: id.rawValue,
      runtime: runtime,
      workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
      command: command,
      environmentVariables: [
        RemotePipeProtocol.socketVariable: ports.socketPath,
        RemotePipeProtocol.tokenVariable: token,
      ],
      commandWrapper: [],
      disableShellIntegration: true,
      initialGeometry: geometry,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
    guard view.surface != nil else {
      view.closeSurface()
      ports.forgetPipe(remoteContentID)
      remoteTerminalLogger.warning("Remote tab not started: no Ghostty surface")
      sessionFailedToStart = true
      return
    }
    sessionFailedToStart = false
    // No `bridge.onDesktopNotification`: OSC 9 / 777 from the remote program posts nothing here.
    // "Agent is waiting" comes from the Mac's `list` (`RemoteClientNotifier`); a BEL is handled by
    // the surface itself, as in a local tab.
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
    ports.detach(remoteContentID)
    ports.forgetPipe(remoteContentID)
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

  /// The surface measured the grid that fits its pane (`onPaneGridMeasured`).
  func paneMeasured(_ grid: RemoteAutoResize.Grid) {
    measuredGrid = grid
    run(driver.paneMeasured(grid))
  }

  /// The session reports the connection's status and the Mac's name, now and on every change. A
  /// status other than online ends the attached state: the banner stays until the next `attached`.
  func linkChanged(status: RemoteClientStatus, hostName: String?, seenOnline: Bool) {
    if self.status != status { self.status = status }
    if !self.seenOnline, seenOnline || status.isOnline { self.seenOnline = true }
    if self.hostName != hostName { self.hostName = hostName }
    if case .online = status { return }
    driver.linkLost()
    mirrorDriver()
  }

  /// The banner kind over this terminal; nil while it is live.
  var bannerKind: RemoteConnectionBanner.Kind? {
    RemoteConnectionBanner.kind(status: status, isAttached: isAttached, wasAttached: wasAttached || seenOnline)
  }

  /// The banner text over this terminal; nil while it is live.
  var bannerText: String? {
    RemoteConnectionBanner.text(
      status: status, isAttached: isAttached, wasAttached: wasAttached || seenOnline, hostName: hostName)
  }

  // MARK: - Effects

  private func run(_ effects: [RemoteTerminalDriver.Effect]) {
    guard !isTornDown else { return }
    for effect in effects {
      switch effect {
      case .attach:
        consume(ports.attach(remoteContentID, Self.scrollback))
      case .writePipe(let bytes):
        ports.writePipe(remoteContentID, bytes)
      case .pin(let grid):
        _ = surfaceView?.pinGrid(columns: grid.columns, rows: grid.rows)
      case .wantGrid(let grid):
        ports.setWantedGrid(remoteContentID, grid)
      case .scheduleSettle:
        scheduleSettle()
      case .sendInput(let bytes):
        ports.sendInput(remoteContentID, bytes)
      case .detach:
        settleTimer?.cancel()
        settleTimer = nil
        ports.detach(remoteContentID)
      }
    }
    mirrorDriver()
  }

  /// Only real changes reach observers: `out` runs through here for every chunk.
  private func mirrorDriver() {
    if phase != driver.phase { phase = driver.phase }
    if remoteGrid != driver.remoteGrid { remoteGrid = driver.remoteGrid }
    if isAttached != driver.isAttached { isAttached = driver.isAttached }
    if wasAttached != driver.wasAttached { wasAttached = driver.wasAttached }
  }

  private func consume(_ stream: AsyncStream<RemoteTerminalEvent>) {
    events?.cancel()
    events = Task { [weak self] in
      for await event in stream {
        guard let self else { return }
        self.run(self.driver.event(event))
      }
      // Ended by the connection, not by `tearDown` (which cancels this task first).
      guard !Task.isCancelled, let self else { return }
      self.run(self.driver.streamEnded())
    }
  }

  private func scheduleSettle() {
    settleTimer?.cancel()
    settleGeneration &+= 1
    let generation = settleGeneration
    let clock = self.clock
    settleTimer = Task { [weak self] in
      do { try await clock.sleep(for: RemoteAutoResize.settle) } catch { return }
      // A sleep that already returned ignores `cancel()`; a newer timer owns the handle.
      guard !Task.isCancelled, let self, self.settleGeneration == generation else { return }
      self.settleTimer = nil
      self.run(self.driver.settled())
    }
  }

  /// `'<app>/Contents/Resources/bin/supacode' remote-pipe '<pipe key>'`, the CLI the app puts on
  /// `PATH` for its terminals. Nil without a resource directory, or for a key that is not one plain
  /// word (its content id comes from the other Mac and lands in a shell command line).
  nonisolated static func pipeCommand(pipeKey: String, resourceURL: URL? = Bundle.main.resourceURL) -> String? {
    guard isPlainWord(pipeKey), let resourceURL else { return nil }
    let cli = resourceURL.appending(path: "bin/supacode", directoryHint: .notDirectory).path(percentEncoded: false)
    return "\(SSHCommand.loginShellQuote(cli)) remote-pipe \(SSHCommand.loginShellQuote(pipeKey))"
  }

  /// Letters, digits, `-`, `_` and `.`, not starting with `-` (an option to the CLI's parser).
  nonisolated private static func isPlainWord(_ value: String) -> Bool {
    guard let first = value.unicodeScalars.first, first != "-" else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
      scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "-_.".unicodeScalars.contains(scalar))
    }
  }
}

extension RemoteTerminalContent: TabContentToolbar {
  var view: AnyView? {
    guard let kind = bannerKind, let text = bannerText else { return nil }
    return AnyView(RemoteConnectionBannerView(kind: kind, text: text))
  }
}
