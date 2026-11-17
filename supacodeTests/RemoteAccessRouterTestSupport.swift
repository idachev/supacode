import Clocks
import ComposableArchitecture
import ConcurrencyExtras
import Foundation
import IdentifiedCollections

@testable import supacode

/// A stand-in for the zmx stream an `attach` starts: records `start`, `stop`
/// and `send`, and hands the router the events a test yields (`emit`).
nonisolated final class FakeRemoteStream: RemoteTerminalStream, @unchecked Sendable {
  /// Pulls the next event from the test's queue for the router's pump.
  private final class Pull: @unchecked Sendable {
    var iterator: AsyncStream<ZmxRemoteStream.Event>.Iterator
    let closedTaken: LockIsolated<Bool>

    init(_ iterator: AsyncStream<ZmxRemoteStream.Event>.Iterator, closedTaken: LockIsolated<Bool>) {
      self.iterator = iterator
      self.closedTaken = closedTaken
    }

    func next() async -> ZmxRemoteStream.Event? {
      let event = await iterator.next()
      if case .closed = event { closedTaken.setValue(true) }
      return event
    }
  }

  let socketPath: String
  let events: AsyncStream<ZmxRemoteStream.Event>
  private let continuation: AsyncStream<ZmxRemoteStream.Event>.Continuation
  /// The `scrollbackRows` of each `start`.
  let starts = LockIsolated<[Int]>([])
  let stopped = LockIsolated(false)
  let sent = LockIsolated<[[UInt8]]>([])
  /// True once the router's pump took a `.closed` event off `events`.
  let closedTaken: LockIsolated<Bool>

  init(socketPath: String) {
    self.socketPath = socketPath
    let (queue, continuation) = AsyncStream.makeStream(of: ZmxRemoteStream.Event.self)
    self.continuation = continuation
    let closedTaken = LockIsolated(false)
    self.closedTaken = closedTaken
    let pull = Pull(queue.makeAsyncIterator(), closedTaken: closedTaken)
    events = AsyncStream(unfolding: { await pull.next() })
  }

  var isStarted: Bool { !starts.value.isEmpty }

  func start(scrollbackRows: Int) {
    starts.withValue { $0.append(scrollbackRows) }
  }

  func send(_ bytes: [UInt8]) -> Bool {
    sent.withValue { $0.append(bytes) }
    return !stopped.value
  }

  func stop() {
    stopped.setValue(true)
    continuation.finish()
  }

  /// Hands `event` to the router's pump, as the zmx reader thread would.
  func emit(_ event: ZmxRemoteStream.Event) {
    continuation.yield(event)
  }
}

/// The frames a LAN phone got, in order.
nonisolated final class RemoteFrameLog: Sendable {
  let frames = LockIsolated<[String]>([])

  func append(_ frame: String) {
    frames.withValue { $0.append(frame) }
  }

  /// Every frame decoded as a JSON object (a frame that is not one is skipped).
  var messages: [[String: Any]] {
    frames.value.compactMap(RemoteRouterTestSupport.decode)
  }

  /// The decoded frames whose `t` is `type`.
  func messages(ofType type: String) -> [[String: Any]] {
    messages.filter { $0["t"] as? String == type }
  }
}

/// A `RemoteHostRouter` on a real store with one worktree whose layout lists
/// `contents` terminal tabs, and with the zmx stream, the socket check and the
/// PTY read replaced (`RemoteStreamIO`), so `attach` runs without a zmx session.
/// Reused by the router suites (attach, watch, layout actions, held size).
@MainActor
final class RemoteRouterHarness {
  nonisolated static let ptyGrid = (columns: 100, rows: 30)

  let router: RemoteHostRouter
  /// Kept here: the terminal manager holds the store weakly.
  let store: StoreOf<AppFeature>
  let terminalManager: WorktreeTerminalManager
  /// The content of every tab the worktree's layout lists, in tab order.
  let contents: [UUID]
  let worktreeID = WorktreeID("/tmp/repo")
  /// Every stream the router made, in order.
  let streams = LockIsolated<[FakeRemoteStream]>([])
  /// Streams made while an earlier stream of the same terminal still ran
  /// (a re-attach must stop the old one first).
  let overlappingStarts = LockIsolated(0)

  /// `liveLayouts`: the store runs `TerminalsFeature` (inert contents, no
  /// session kills), so layout actions the router sends really change the
  /// layout; otherwise the reducer is a no-op and the layout never changes.
  init(clock: TestClock<Duration>, tabs: Int = 2, liveLayouts: Bool = false) {
    let contents = (0..<tabs).map { _ in UUID() }
    self.contents = contents
    let worktree = Worktree(
      id: worktreeID, name: "repo", detail: "detail", workingDirectory: URL(fileURLWithPath: "/tmp/repo"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"))
    let repository = Repository(
      id: "/tmp/repo", rootURL: URL(fileURLWithPath: "/tmp/repo"), name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree]))
    var repositories = RepositoriesFeature.State()
    repositories.repositories = [repository]
    var state = AppFeature.State(repositories: repositories)
    state.terminals = TerminalsFeature.State(layouts: [
      LayoutFeature.State(id: worktreeID, layout: Self.layout(contents: contents))
    ])
    let store = liveLayouts ? Self.liveLayoutStore(state, clock: clock) : Self.readOnlyStore(state)
    self.store = store
    let terminalManager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    terminalManager.appStore = store
    self.terminalManager = terminalManager
    let streams = self.streams
    let overlappingStarts = self.overlappingStarts
    let streamIO = RemoteStreamIO(
      makeStream: { socketPath in
        let stream = FakeRemoteStream(socketPath: socketPath)
        streams.withValue { made in
          if made.contains(where: { $0.socketPath == socketPath && !$0.stopped.value }) {
            overlappingStarts.withValue { $0 += 1 }
          }
          made.append(stream)
        }
        return stream
      },
      socketExists: { _ in true },
      ptySize: { _ in Self.ptyGrid })
    router = RemoteHostRouter(
      source: RemoteSnapshotSource(store: store, terminalManager: terminalManager),
      hostName: "Mac", hostID: nil, appLabel: nil, clock: clock, streamIO: streamIO)
  }

  nonisolated deinit {}

  /// No reducer logic: the router only reads the state (a resize's wake is a no-op here).
  private static func readOnlyStore(_ state: AppFeature.State) -> StoreOf<AppFeature> {
    Store(initialState: state) {
      Reduce<AppFeature.State, AppFeature.Action> { _, _ in .none }
    }
  }

  /// The terminals slice runs for real; contents are inert, so no surface or session starts.
  private static func liveLayoutStore(_ state: AppFeature.State, clock: TestClock<Duration>) -> StoreOf<AppFeature> {
    Store(initialState: state) {
      Scope(state: \.terminals, action: \.terminals) { TerminalsFeature() }
    } withDependencies: {
      $0.continuousClock = clock
      $0.uuid = .incrementing
      // One shared registry: the per-access `testValue` would hand provision and lookup different runtimes.
      $0.contentRuntime = ContentRuntime()
      $0[LayoutContentFactory.self] = LayoutContentFactory { request in
        InertTabContent(id: request.contentID, state: request.content)
      }
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
      $0[MemoryPressureClient.self] = MemoryPressureClient(warnings: { AsyncStream { $0.finish() } })
    }
  }

  /// The worktree's layout as the store holds it now.
  var layout: PaneLayout? {
    store.withState { $0.terminals.layouts[id: worktreeID]?.layout }
  }

  /// One pane with a terminal tab per content.
  private static func layout(contents: [UUID]) -> PaneLayout {
    let paneID = PaneID()
    let tabs = contents.map { content in
      TabItem(
        id: TabID(), title: "Tab",
        content: ContentSnapshot(
          id: ContentID(rawValue: content), state: .terminal(TerminalContentState(workingDirectory: nil))))
    }
    return PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [Pane(id: paneID, tabs: IdentifiedArray(uniqueElements: tabs), selectedTabID: tabs.first?.id)],
      focusedPaneID: paneID)
  }

  /// Opens a LAN phone whose frames land in the returned log.
  func openPhone(_ connID: String) -> RemoteFrameLog {
    RemoteRouterTestSupport.openPhone(connID, on: router)
  }

  /// Sends one application message from `connID`.
  func send(_ connID: String, _ json: String) {
    router.receiveDirect(connID: connID, json: Data(json.utf8))
  }

  /// The streams the router made for `contentID`, oldest first.
  func streams(of contentID: UUID) -> [FakeRemoteStream] {
    let path = ZmxRemoteStream.socketPath(contentID: contentID)
    return streams.value.filter { $0.socketPath == path }
  }
}

/// Router fixtures shared by the router suites.
@MainActor
enum RemoteRouterTestSupport {
  /// Opens a LAN phone on `router` whose frames land in the returned log.
  static func openPhone(_ connID: String, on router: RemoteHostRouter) -> RemoteFrameLog {
    let log = RemoteFrameLog()
    router.lanOpened(connID) { frame in log.append(frame) }
    return log
  }

  /// A frame decoded as a JSON object; nil when it is not one.
  nonisolated static func decode(_ frame: String) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(frame.utf8))) as? [String: Any]
  }

  /// Yields until `condition` holds, for a bounded number of turns (no clock
  /// time passes). Returns whether it held.
  @discardableResult
  static func settle(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<500 {
      if condition() { return true }
      await Task.megaYield()
    }
    return condition()
  }
}
