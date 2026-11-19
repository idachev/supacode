import AppKit
import ConcurrencyExtras
import Foundation
import Observation
import SupacodeSettingsShared

nonisolated private let sessionLogger = SupaLogger("RemoteClient")

/// The live objects behind the remote window: the connection to the selected Mac, the pipe server
/// the remote tabs' surfaces talk to, and one `RemoteTerminalContent` per remote content id.
///
/// Order is load-bearing:
/// - the pipe server listens before any content starts its surface (the surface's `remote-pipe`
///   connects at once);
/// - `open` and `close` tear every content down first (each sends its `detach` on the old
///   connection, which releases the held size on the Mac, ТР8б), then stop the connection
///   (a stopped connection ends every terminal stream, and its deinit does not), and `close`
///   stops the pipe server last (its `onClosed` reports for torn-down contents find nothing).
///
/// Nothing here enters the local window's state: the contents live in the session's own
/// `ContentRuntime`, never `ContentRuntime.liveValue` (ПЗ3).
@MainActor
@Observable
final class RemoteClientSession {
  typealias Event = RemoteClientSessionClient.Event

  /// The CLI socket's directory (`AgentHookSocketServer`): short enough for `sun_path`.
  nonisolated static var pipeDirectory: URL {
    URL(filePath: "/tmp/supacode-\(getuid())", directoryHint: .isDirectory)
  }

  let pipes: RemotePipeServer
  /// Its own registry, never `ContentRuntime.liveValue`.
  let runtime: ContentRuntime
  /// This Mac's own host id: never pickable, never counted (МХ2).
  let ownHostID: String?
  /// nil without a key file, and after `close()`.
  private(set) var connection: RemoteClientConnection?
  /// Grows on every `open` and `close`: every content made before is gone.
  private(set) var epoch = 0

  @ObservationIgnored private let ghostty: GhosttyRuntime
  @ObservationIgnored private let sockets: RemoteClientSocketFactory
  @ObservationIgnored private let clock: any Clock<Duration>
  @ObservationIgnored private let loadKey: () -> RemoteClientKey?
  /// Remote content id → its one content. Read and written from view tasks, so never observed.
  @ObservationIgnored private var contents: [String: RemoteTerminalContent] = [:]
  @ObservationIgnored private var subscriber: AsyncStream<Event>.Continuation?
  /// What the subscriber was last told, so only a real change becomes an event.
  @ObservationIgnored private var published = Published()

  private struct Published: Equatable {
    var status: RemoteClientStatus = .idle
    var hostName: String?
    var hosts: [RemoteClientHostInfo]?
    var listRevision = 0
  }

  init(
    ghostty: GhosttyRuntime,
    sockets: RemoteClientSocketFactory = .live,
    clock: any Clock<Duration> = ContinuousClock(),
    pipeDirectory: URL = RemoteClientSession.pipeDirectory,
    ownHostID: String? = RemoteAccessConfig.currentHostID,
    loadKey: @escaping () -> RemoteClientKey? = { RemoteClientKey.load() }
  ) {
    self.ghostty = ghostty
    self.sockets = sockets
    self.clock = clock
    self.ownHostID = ownHostID
    self.loadKey = loadKey
    pipes = RemotePipeServer(directory: pipeDirectory)
    runtime = ContentRuntime()
    // The server has one callback of each kind for every pipe: route by content id. A report for
    // a content that is gone (torn down, or the pipe server stopping) finds nothing.
    pipes.onOpened = { [weak self] contentID in
      self?.contents[contentID]?.pipeOpened()
    }
    pipes.onInput = { [weak self] contentID, bytes in
      self?.contents[contentID]?.pipeInput(bytes)
    }
    pipes.onClosed = { [weak self] contentID in
      self?.contents[contentID]?.pipeClosed()
    }
  }

  /// The connection must be stopped before release (`close()`); the window's session lives as
  /// long as the app.
  nonisolated deinit {}

  // MARK: - Lifetime

  /// Builds the connection from the key file and starts it, bound to `hostID` or unbound (nil).
  /// A live connection is replaced: its contents are torn down and it is stopped first.
  func open(hostID: String?) {
    tearDownContents()
    connection?.stop()
    connection = nil
    epoch += 1
    // A new connection counts its lists from zero.
    published.listRevision = 0
    guard let key = loadKey() else {
      sessionLogger.warning("Remote client not started: no usable key file")
      return
    }
    do {
      try pipes.start()
    } catch {
      sessionLogger.warning("Remote pipe server did not start; remote tabs cannot show output")
    }
    let connection = RemoteClientConnection(key: key, ownHostID: ownHostID, sockets: sockets, clock: clock)
    self.connection = connection
    connection.start(hostID: hostID)
    sessionLogger.info("Remote client started (bound: \(hostID != nil))")
    observe(connection)
  }

  /// Tears down every content, then stops the connection, then the pipe server.
  func close() {
    tearDownContents()
    connection?.stop()
    connection = nil
    pipes.stop()
    epoch += 1
    // The reducer resets its copy when the window closes; the next connection reports afresh.
    published = Published()
    sessionLogger.info("Remote client closed")
  }

  // MARK: - Contents

  /// The content for this remote terminal, made and started once and then cached. A content
  /// whose surface did not start, or made with no connection, is returned but not kept, so the
  /// next call tries again.
  func content(for remoteContentID: String, title: String) -> RemoteTerminalContent {
    if let existing = contents[remoteContentID] { return existing }
    let content = RemoteTerminalContent(
      remoteContentID: remoteContentID,
      title: title,
      ports: ports(for: connection),
      runtime: ghostty,
      clock: clock
    )
    // Not started without a connection (no key file, or after `close()`): nothing could reach it.
    guard connection != nil else { return content }
    // Cached before the surface starts: its pipe may open before `provision` returns.
    contents[remoteContentID] = content
    guard runtime.provision(content, at: runtime.spawnGeometry(near: nil)) else {
      contents[remoteContentID] = nil
      return content
    }
    if let surface = content.renderer as? GhosttySurfaceView { Self.wire(surface) }
    return content
  }

  /// Tears down one content (it detaches and its pipe closes).
  func release(_ remoteContentID: String) {
    guard let content = contents.removeValue(forKey: remoteContentID) else { return }
    runtime.remove(content.id, tombstone: false)
    content.tearDown()
  }

  /// Tears down every content but `remoteContentID` (nil: all of them), so a terminal the window no
  /// longer shows lets go of the Mac and its held size (ТР8б).
  func releaseAll(except remoteContentID: String?) {
    for id in Array(contents.keys) where id != remoteContentID {
      release(id)
    }
  }

  private func tearDownContents() {
    // Emptied first: `tearDown` forgets the pipe, whose `onClosed` comes back at once.
    let all = contents.values
    contents = [:]
    for content in all {
      runtime.remove(content.id, tombstone: false)
      content.tearDown()
    }
  }

  /// The connection the content was made for. Held weakly: a replaced connection is stopped and
  /// its contents torn down, so a late call must not keep it alive.
  private func ports(for connection: RemoteClientConnection?) -> RemoteTerminalContent.Ports {
    let pipes = pipes
    return RemoteTerminalContent.Ports(
      attach: { [weak connection] contentID, scrollback in
        connection?.attach(contentID: contentID, scrollback: scrollback) ?? .finished
      },
      detach: { [weak connection] in connection?.detach(contentID: $0) },
      sendInput: { [weak connection] in _ = connection?.sendInput(contentID: $0, bytes: $1) },
      setWantedGrid: { [weak connection] in
        connection?.setWantedGrid(contentID: $0, columns: $1.columns, rows: $1.rows)
      },
      socketPath: pipes.socketPath,
      expectPipe: { pipes.expect(contentID: $0) },
      forgetPipe: { pipes.forget(contentID: $0) },
      writePipe: { pipes.write(contentID: $0, $1) }
    )
  }

  /// A remote surface reaches nothing of the local window. The bell needs no wiring: the bridge
  /// counts it as for a local surface, by the laptop's Ghostty settings (ИВ4). OSC 9 / 777
  /// notifications get no handler, so the bridge drops them (ИВ4). A Ghostty keybinding for the
  /// layout is consumed and ignored, as on a local surface: the remote layout belongs to the Mac.
  private static func wire(_ surface: GhosttySurfaceView) {
    surface.bridge.onNewTab = { true }
    surface.bridge.onCloseTab = { _ in true }
    surface.bridge.onSplitAction = { _ in true }
    surface.bridge.onGotoTab = { _ in true }
    surface.bridge.onMoveTab = { _ in true }
  }

  // MARK: - Events

  /// The reports for the reducer. A new call ends the previous subscriber's stream.
  func events() -> AsyncStream<Event> {
    subscriber?.finish()
    let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
    subscriber = continuation
    return stream
  }

  /// Reads the connection's reported state under observation tracking and re-arms on every
  /// change, while that connection is still the session's.
  private func observe(_ connection: RemoteClientConnection) {
    guard self.connection === connection else { return }
    let (current, list) = withObservationTracking {
      (
        Published(
          status: connection.status,
          hostName: connection.hostName,
          hosts: connection.hosts,
          listRevision: connection.listRevision
        ),
        connection.list
      )
    } onChange: { [weak self, weak connection] in
      Task { @MainActor [weak self, weak connection] in
        guard let self, let connection else { return }
        self.observe(connection)
      }
    }
    publish(current, list: list)
  }

  private func publish(_ current: Published, list: RemoteClientList?) {
    let previous = published
    published = current
    guard let subscriber else { return }
    if current.status != previous.status { subscriber.yield(.statusChanged(current.status)) }
    if current.hostName != previous.hostName { subscriber.yield(.hostNameChanged(current.hostName)) }
    if current.hosts != previous.hosts { subscriber.yield(.hostsChanged(current.hosts)) }
    if current.listRevision != previous.listRevision, let list { subscriber.yield(.listChanged(list)) }
  }
}
