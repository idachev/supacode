import Clocks
import ComposableArchitecture
import ConcurrencyExtras
import Foundation
import IdentifiedCollections

@testable import supacode

/// A stand-in for the zmx stream an `attach` starts: records `start`, `stop`
/// and `send`, and hands the router the events a test yields (`emit`).
nonisolated final class FakeRemoteStream: RemoteTerminalStream, @unchecked Sendable {
  /// A one-shot gate: `wait` returns once `open` was called, also when it was
  /// called first. Not cancellation-aware on purpose: a cancelled pump parked
  /// here stays parked until the test opens it.
  nonisolated final class Latch: Sendable {
    private let state = LockIsolated<(isOpen: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func open() {
      let waiters = state.withValue { state -> [CheckedContinuation<Void, Never>] in
        guard !state.isOpen else { return [] }
        state.isOpen = true
        let waiters = state.waiters
        state.waiters = []
        return waiters
      }
      for waiter in waiters { waiter.resume() }
    }

    func wait() async {
      await withCheckedContinuation { continuation in
        let isOpen = state.withValue { state -> Bool in
          if !state.isOpen { state.waiters.append(continuation) }
          return state.isOpen
        }
        if isOpen { continuation.resume() }
      }
    }
  }

  /// Which events the pump parks (`hold(_:)`).
  nonisolated enum HeldEvent: Sendable {
    case closed
    case output
  }

  /// An event of the held kind that the pump took off `events` but hands to
  /// the router only once the test releases it (`hold(_:)`).
  nonisolated final class EventHold: Sendable {
    let kind: HeldEvent
    let taken = Latch()
    let release = Latch()

    init(kind: HeldEvent) {
      self.kind = kind
    }

    func matches(_ event: ZmxRemoteStream.Event?) -> Bool {
      switch (kind, event) {
      case (.closed, .closed?): true
      case (.output, .output?), (.output, .snapshot?): true
      default: false
      }
    }
  }

  /// Pulls the next event from the test's queue for the router's pump.
  private final class Pull: @unchecked Sendable {
    var iterator: AsyncStream<ZmxRemoteStream.Event>.Iterator
    let eventHold: LockIsolated<EventHold?>

    init(_ iterator: AsyncStream<ZmxRemoteStream.Event>.Iterator, eventHold: LockIsolated<EventHold?>) {
      self.iterator = iterator
      self.eventHold = eventHold
    }

    func next() async -> ZmxRemoteStream.Event? {
      let event = await iterator.next()
      if let hold = eventHold.value, hold.matches(event) {
        hold.taken.open()
        await hold.release.wait()
      }
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
  /// Set by `hold(_:)`; without it every event reaches the router at once.
  private let eventHold: LockIsolated<EventHold?>

  init(socketPath: String) {
    self.socketPath = socketPath
    let (queue, continuation) = AsyncStream.makeStream(of: ZmxRemoteStream.Event.self)
    self.continuation = continuation
    let eventHold = LockIsolated<EventHold?>(nil)
    self.eventHold = eventHold
    let pull = Pull(queue.makeAsyncIterator(), eventHold: eventHold)
    events = AsyncStream(unfolding: { await pull.next() })
  }

  /// From now on the pump parks the next event of `kind` it takes until
  /// `releaseHeld()`, so the test decides when the router's pump hands it on.
  func hold(_ kind: HeldEvent) {
    eventHold.setValue(EventHold(kind: kind))
  }

  /// Returns once the pump took a held event off `events`; it has not reached
  /// the router yet. Returns at once when nothing is held.
  func heldTaken() async {
    await eventHold.value?.taken.wait()
  }

  /// Hands a held event on to the router's pump (idempotent).
  func releaseHeld() {
    eventHold.value?.release.open()
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
  /// The grid every PTY read returns; a test changes it to stand in for the
  /// session taking another size.
  let ptySize = LockIsolated<(columns: Int, rows: Int)>(RemoteRouterHarness.ptyGrid)
  /// Whether the session sockets exist (`RemoteStreamIO.socketExists`), and
  /// how many times the router checked.
  let socketsUp: LockIsolated<Bool>
  let socketChecks = LockIsolated(0)
  /// The terminal contents the snapshot source finds (`registerTerminal`);
  /// the process-wide `ContentRuntime.liveValue` stays untouched.
  let terminals = RemoteTestTerminals()

  /// `liveLayouts`: the store runs `TerminalsFeature` (inert contents, no
  /// session kills), so layout actions the router sends really change the
  /// layout; otherwise the reducer is a no-op and the layout never changes.
  init(clock: TestClock<Duration>, tabs: Int = 2, liveLayouts: Bool = false, socketsUp: Bool = true) {
    self.socketsUp = LockIsolated(socketsUp)
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
    let ptySize = self.ptySize
    let sockets = self.socketsUp
    let socketChecks = self.socketChecks
    let terminals = self.terminals
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
      socketExists: { _ in
        socketChecks.withValue { $0 += 1 }
        return sockets.value
      },
      ptySize: { _ in ptySize.value })
    router = RemoteHostRouter(
      source: RemoteSnapshotSource(
        store: store, terminalManager: terminalManager, content: { terminals.byID[$0] }),
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

  /// Registers a terminal content for `contentID` that never started a
  /// surface, so the router's pin and unpin reach it and leave `pinnedGrid`.
  @discardableResult
  func registerTerminal(_ contentID: UUID) -> TerminalContent {
    let content = TerminalContent(
      id: ContentID(rawValue: contentID), makeSurface: { _, _, _ in nil },
      initialState: TerminalContentState(workingDirectory: nil))
    terminals.byID[content.id] = content
    return content
  }

  /// The streams the router made for `contentID`, oldest first.
  func streams(of contentID: UUID) -> [FakeRemoteStream] {
    let path = ZmxRemoteStream.socketPath(contentID: contentID)
    return streams.value.filter { $0.socketPath == path }
  }
}

/// The contents a harness's snapshot source looks up instead of the app's
/// `ContentRuntime.liveValue`.
@MainActor
final class RemoteTestTerminals {
  var byID: [ContentID: any TabContent] = [:]

  nonisolated init() {}

  nonisolated deinit {}
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

  /// Moves `clock` forward by `total` in steps of `increment`, yielding before
  /// each so the router's sleeps are registered.
  static func step(
    _ clock: TestClock<Duration>, by total: Duration, increment: Duration = .milliseconds(250)
  ) async {
    var elapsed: Duration = .zero
    while elapsed < total {
      await Task.megaYield()
      await clock.advance(by: increment)
      elapsed += increment
    }
    await Task.megaYield()
  }

  /// Steps `clock` in `increment`s until `condition` holds, for at most
  /// `limit`, settling before each step (`settle`). Returns whether it held.
  /// Never one big `advance`: under parallel load a sleep registered late
  /// would miss it and the wait would hang.
  @discardableResult
  static func step(
    _ clock: TestClock<Duration>, until condition: () -> Bool, within limit: Duration,
    increment: Duration = .milliseconds(250)
  ) async -> Bool {
    var elapsed: Duration = .zero
    while elapsed < limit {
      if await settle(condition) { return true }
      await clock.advance(by: increment)
      elapsed += increment
    }
    return await settle(condition)
  }
}
