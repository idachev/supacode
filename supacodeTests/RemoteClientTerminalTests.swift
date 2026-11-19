import Clocks
import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

struct RemoteClientTerminalTests {
  typealias Grid = RemoteAutoResize.Grid

  @Test func aMeasurementSchedulesAndTheSameOneDoesNot() {
    var auto = RemoteAutoResize()
    let first = auto.paneMeasured(Grid(columns: 120, rows: 40))
    let again = auto.paneMeasured(Grid(columns: 120, rows: 40))
    #expect(first == .schedule)
    #expect(again == .nothing)
  }
  @Test func settlingSendsOnlyWhenAttachedAndDifferent() {
    var auto = RemoteAutoResize()
    _ = auto.paneMeasured(Grid(columns: 120, rows: 40))
    let beforeAttach = auto.settled()
    #expect(beforeAttach == .nothing)
    let onAttach = auto.attached(remote: Grid(columns: 180, rows: 50))
    #expect(onAttach == .send(Grid(columns: 120, rows: 40)))
    auto.sizeReceived(Grid(columns: 120, rows: 40))
    _ = auto.paneMeasured(Grid(columns: 100, rows: 30))
    let afterResize = auto.settled()
    #expect(afterResize == .send(Grid(columns: 100, rows: 30)))
  }
  @Test func anAttachedThatAlreadyFitsSendsNothing() {
    var auto = RemoteAutoResize()
    _ = auto.paneMeasured(Grid(columns: 120, rows: 40))
    let step = auto.attached(remote: Grid(columns: 120, rows: 40))
    #expect(step == .nothing)
  }
  @Test func aForeignSizeIsNeverAnswered() {
    var auto = RemoteAutoResize()
    _ = auto.paneMeasured(Grid(columns: 120, rows: 40))
    _ = auto.attached(remote: Grid(columns: 120, rows: 40))
    auto.sizeReceived(Grid(columns: 80, rows: 24))  // another client took the size
    let step = auto.settled()  // no new pane measurement happened
    #expect(step == .nothing)
  }
  @Test func theRedrawPreambleClearsHistoryThenScreenThenHomes() {
    #expect(RemoteTerminalBytes.clearForRedraw == Array("\u{1b}[3J\u{1b}[2J\u{1b}[H".utf8))
  }

  // MARK: - The content's event handling

  typealias Driver = RemoteTerminalDriver

  /// A driver whose pipe opened and whose terminal attached at 80 × 24.
  private static func liveDriver(measured: Grid? = nil) -> Driver {
    var driver = Driver()
    _ = driver.pipeOpened()
    if let measured { _ = driver.paneMeasured(measured) }
    _ = driver.event(.attached(cols: 80, rows: 24))
    return driver
  }

  @Test func thePipeOpeningAttachesOnce() {
    var driver = Driver()
    let first = driver.pipeOpened()
    let again = driver.pipeOpened()
    #expect(first == [.attach])
    #expect(again == [])
    #expect(driver.phase == .starting)
  }

  @Test func anAttachedClearsThenPinsThenAsksForThePaneGrid() {
    var driver = Driver()
    _ = driver.pipeOpened()
    _ = driver.paneMeasured(Grid(columns: 120, rows: 40))
    let effects = driver.event(.attached(cols: 80, rows: 24))
    #expect(
      effects == [
        .writePipe(RemoteTerminalBytes.clearForRedraw), .pin(Grid(columns: 80, rows: 24)),
        .wantGrid(Grid(columns: 120, rows: 40)),
      ])
    #expect(driver.phase == .live)
    #expect(driver.remoteGrid == Grid(columns: 80, rows: 24))
  }

  @Test func everyNewAttachedRedrawsFromAClearScreen() {
    var driver = Self.liveDriver()
    let again = driver.event(.attached(cols: 100, rows: 30))
    #expect(again == [.writePipe(RemoteTerminalBytes.clearForRedraw), .pin(Grid(columns: 100, rows: 30))])
  }

  @Test func outputLosesItsQueriesOnTheWayToThePipe() {
    var driver = Self.liveDriver()
    let effects = driver.event(.out(Array("a\u{1b}[cb".utf8)))
    #expect(effects == [.writePipe(Array("ab".utf8))])
    let onlyQuery = driver.event(.out(Array("\u{1b}[6n".utf8)))
    #expect(onlyQuery == [])
  }

  @Test func aNewAttachedDropsAHalfQueryFromTheOldStream() {
    var driver = Self.liveDriver()
    _ = driver.event(.out(Array("\u{1b}[".utf8)))
    _ = driver.event(.attached(cols: 80, rows: 24))
    let redraw = driver.event(.out(Array("6n".utf8)))
    #expect(redraw == [.writePipe(Array("6n".utf8))])
  }

  @Test func aSizePinsWithoutAskingBack() {
    var driver = Self.liveDriver(measured: Grid(columns: 120, rows: 40))
    let effects = driver.event(.size(cols: 90, rows: 30))
    #expect(effects == [.pin(Grid(columns: 90, rows: 30))])
    #expect(driver.remoteGrid == Grid(columns: 90, rows: 30))
    let settled = driver.settled()
    #expect(settled == [])
  }

  @Test func aSettledPaneAsksForItsGrid() {
    var driver = Self.liveDriver()
    let measured = driver.paneMeasured(Grid(columns: 120, rows: 40))
    #expect(measured == [.scheduleSettle])
    let settled = driver.settled()
    #expect(settled == [.wantGrid(Grid(columns: 120, rows: 40))])
  }

  @Test func pipeInputGoesToTheHost() {
    var driver = Self.liveDriver()
    let effects = driver.pipeInput([0x61])
    #expect(effects == [.sendInput([0x61])])
  }

  @Test func detachedEndsTheTabAndDetachesIt() {
    var driver = Self.liveDriver()
    let effects = driver.event(.detached(reason: "exited"))
    #expect(effects == [.detach])
    #expect(driver.phase == .ended(reason: "exited"))
  }

  @Test func afterTheEndInputAndEventsAreIgnored() {
    var driver = Self.liveDriver()
    _ = driver.event(.detached(reason: "exited"))
    let input = driver.pipeInput([0x61])
    let attached = driver.event(.attached(cols: 80, rows: 24))
    let out = driver.event(.out([0x61]))
    let measured = driver.paneMeasured(Grid(columns: 120, rows: 40))
    let closed = driver.pipeClosed()
    #expect(input == [])
    #expect(attached == [])
    #expect(out == [])
    #expect(measured == [])
    #expect(closed == [])
    #expect(driver.phase == .ended(reason: "exited"))
  }

  @Test func aClosedPipeEndsTheTabAndDetachesIt() {
    var driver = Self.liveDriver()
    let effects = driver.pipeClosed()
    #expect(effects == [.detach])
    #expect(driver.phase == .ended(reason: Driver.pipeClosedReason))
  }

  @Test func aStreamThatEndsSilentlyEndsTheTab() {
    var driver = Self.liveDriver()
    let effects = driver.streamEnded()
    let input = driver.pipeInput([0x61])
    #expect(effects == [])
    #expect(driver.phase == .ended(reason: Driver.streamEndedReason))
    #expect(input == [])
  }

  @Test func aStreamEndAfterDetachedKeepsTheHostsReason() {
    var driver = Self.liveDriver()
    _ = driver.event(.detached(reason: "exited"))
    let effects = driver.streamEnded()
    #expect(effects == [])
    #expect(driver.phase == .ended(reason: "exited"))
  }

  @Test func inputBeforeThePipeOpensIsDropped() {
    var driver = Driver()
    let input = driver.pipeInput([0x61])
    let closed = driver.pipeClosed()
    #expect(input == [])
    #expect(closed == [])
  }

  @Test func thePipeCommandQuotesTheCLIAndTheID() {
    let command = RemoteTerminalContent.pipeCommand(
      pipeKey: "6F9619FF-8B86-D011-B42D-00C04FC964FF",
      resourceURL: URL(filePath: "/Apps/My Supacode.app/Contents/Resources", directoryHint: .isDirectory)
    )
    #expect(
      command
        == "'/Apps/My Supacode.app/Contents/Resources/bin/supacode' remote-pipe '6F9619FF-8B86-D011-B42D-00C04FC964FF'")
  }

  @Test func anIDThatIsNotAPlainWordGetsNoCommand() {
    let resources = URL(filePath: "/Apps/Supacode.app/Contents/Resources", directoryHint: .isDirectory)
    for id in ["", "-h", "--help", "a b", "a;rm", "$(x)", "a'b", "é"] {
      #expect(RemoteTerminalContent.pipeCommand(pipeKey: id, resourceURL: resources) == nil)
    }
    #expect(RemoteTerminalContent.pipeCommand(pipeKey: "abc", resourceURL: nil) == nil)
  }

  @Test func theSnapshotIsNeverPersisted() {
    let snapshot = RemoteTerminalContent.snapshot(id: ContentID())
    #expect(snapshot.kind == .terminal)
    #expect(snapshot.state.isEphemeral)
  }

  // MARK: - The content over stand-in ports

  @MainActor
  @Test func theSettleTimerRestartsOnANewerMeasurementAndFiresOnce() async {
    let clock = TestClock<Duration>()
    let ports = RemoteTerminalPortsRecorder()
    let content = ports.liveContent(clock: clock)
    defer { content.tearDown() }
    _ = await RemoteRouterTestSupport.settle { content.phase == .live }

    content.paneMeasured(Grid(columns: 120, rows: 40))
    await RemoteRouterTestSupport.step(clock, by: .milliseconds(150), increment: .milliseconds(50))
    content.paneMeasured(Grid(columns: 100, rows: 30))
    await RemoteRouterTestSupport.step(clock, by: .milliseconds(150), increment: .milliseconds(50))
    #expect(ports.wanted == [])

    let fired = await RemoteRouterTestSupport.step(
      clock, until: { !ports.wanted.isEmpty }, within: .seconds(1), increment: .milliseconds(50))
    #expect(fired)
    await RemoteRouterTestSupport.step(clock, by: .seconds(1), increment: .milliseconds(50))
    #expect(ports.wanted == [Grid(columns: 100, rows: 30)])
  }

  @MainActor
  @Test func tearDownIsIdempotentAndTheForgetsCloseIsANoOp() async {
    let clock = TestClock<Duration>()
    let ports = RemoteTerminalPortsRecorder()
    let content = ports.liveContent(clock: clock)
    _ = await RemoteRouterTestSupport.settle { content.phase == .live }
    // The pipe server reports the pipe it closes in `forget` at once.
    ports.onForget = { content.pipeClosed() }

    content.tearDown()
    content.tearDown()
    #expect(ports.detaches == 1)
    #expect(ports.forgets == 1)
    #expect(content.phase == .live)

    let writesBefore = ports.writes.count
    ports.continuation?.yield(.out(Array("late".utf8)))
    content.pipeInput([0x61])
    for _ in 0..<10 { await Task.megaYield() }
    #expect(ports.writes.count == writesBefore)
    #expect(ports.inputs == [])
  }

  @MainActor
  @Test func theClearPreambleReachesThePipeBeforeTheFirstOut() async {
    let ports = RemoteTerminalPortsRecorder()
    let content = ports.content(clock: TestClock<Duration>())
    defer { content.tearDown() }
    content.pipeOpened()
    ports.continuation?.yield(.attached(cols: 80, rows: 24))
    ports.continuation?.yield(.out(Array("hi".utf8)))
    let wrote = await RemoteRouterTestSupport.settle { ports.writes.count == 2 }
    #expect(wrote)
    #expect(ports.writes == [RemoteTerminalBytes.clearForRedraw, Array("hi".utf8)])
  }

  @MainActor
  @Test func aSilentlyFinishedStreamEndsTheContent() async {
    let ports = RemoteTerminalPortsRecorder()
    let content = ports.liveContent(clock: TestClock<Duration>())
    defer { content.tearDown() }
    _ = await RemoteRouterTestSupport.settle { content.phase == .live }

    ports.continuation?.finish()
    let ended = await RemoteRouterTestSupport.settle {
      content.phase == .ended(reason: Driver.streamEndedReason)
    }
    #expect(ended)
    content.pipeInput([0x61])
    #expect(ports.inputs == [])
    #expect(ports.detaches == 0)
  }
}

/// Stands in for the connection and the pipe server under a `RemoteTerminalContent`.
@MainActor
final class RemoteTerminalPortsRecorder {
  var writes: [[UInt8]] = []
  var inputs: [[UInt8]] = []
  var wanted: [RemoteAutoResize.Grid] = []
  var detaches = 0
  var forgets = 0
  var continuation: AsyncStream<RemoteTerminalEvent>.Continuation?
  var onForget: (() -> Void)?

  nonisolated deinit {}

  func content(clock: any Clock<Duration>) -> RemoteTerminalContent {
    RemoteTerminalContent(remoteContentID: "c1", title: "Tab", ports: ports(), runtime: GhosttyRuntime(), clock: clock)
  }

  /// A content whose pipe opened and whose terminal attached at 80 × 24 (settle until `.live`).
  func liveContent(clock: any Clock<Duration>) -> RemoteTerminalContent {
    let content = content(clock: clock)
    content.pipeOpened()
    continuation?.yield(.attached(cols: 80, rows: 24))
    return content
  }

  private func ports() -> RemoteTerminalContent.Ports {
    RemoteTerminalContent.Ports(
      attach: { _, _ in
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteTerminalEvent.self)
        self.continuation = continuation
        return stream
      },
      detach: { _ in
        self.detaches += 1
        self.continuation?.finish()
      },
      sendInput: { _, bytes in self.inputs.append(bytes) },
      setWantedGrid: { _, grid in self.wanted.append(grid) },
      socketPath: "/tmp/none.sock",
      expectPipe: { _ in "token" },
      forgetPipe: { _ in
        self.forgets += 1
        self.onForget?()
      },
      writePipe: { _, bytes in self.writes.append(bytes) }
    )
  }
}
