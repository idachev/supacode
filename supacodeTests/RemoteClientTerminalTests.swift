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

  @Test func inputBeforeThePipeOpensIsDropped() {
    var driver = Driver()
    let input = driver.pipeInput([0x61])
    let closed = driver.pipeClosed()
    #expect(input == [])
    #expect(closed == [])
  }

  @Test func thePipeCommandQuotesTheCLIAndTheID() {
    let command = RemoteTerminalContent.pipeCommand(
      remoteContentID: "6F9619FF-8B86-D011-B42D-00C04FC964FF",
      resourceURL: URL(filePath: "/Apps/My Supacode.app/Contents/Resources", directoryHint: .isDirectory)
    )
    #expect(
      command
        == "'/Apps/My Supacode.app/Contents/Resources/bin/supacode' remote-pipe '6F9619FF-8B86-D011-B42D-00C04FC964FF'")
  }

  @Test func anIDThatIsNotAPlainWordGetsNoCommand() {
    let resources = URL(filePath: "/Apps/Supacode.app/Contents/Resources", directoryHint: .isDirectory)
    for id in ["", "-h", "--help", "a b", "a;rm", "$(x)", "a'b", "é"] {
      #expect(RemoteTerminalContent.pipeCommand(remoteContentID: id, resourceURL: resources) == nil)
    }
    #expect(RemoteTerminalContent.pipeCommand(remoteContentID: "abc", resourceURL: nil) == nil)
  }

  @Test func theSnapshotIsNeverPersisted() {
    let snapshot = RemoteTerminalContent.snapshot(id: ContentID())
    #expect(snapshot.kind == .terminal)
    #expect(snapshot.state.isEphemeral)
  }
}
