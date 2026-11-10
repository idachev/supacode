import Clocks
import ConcurrencyExtras
import CoreGraphics
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

/// The `tab.new` rules that need no live app store: which worktrees refuse a
/// tab, and the bounded wait for the new tab (`RemoteHostRouter.poll`).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RemoteAccessTabNewTests {
  @Test func onlyAKnownLiveWorktreeGetsATab() {
    #expect(RemoteTabNewRejection.check(found: true, isArchived: false, isMissing: false) == nil)
    #expect(RemoteTabNewRejection.check(found: false, isArchived: false, isMissing: false) == .unknownWorktree)
    #expect(RemoteTabNewRejection.check(found: true, isArchived: true, isMissing: false) == .archivedWorktree)
    #expect(RemoteTabNewRejection.check(found: true, isArchived: false, isMissing: true) == .missingWorktree)
    #expect(RemoteTabNewRejection.check(found: true, isArchived: true, isMissing: true) == .archivedWorktree)
  }

  // MARK: - Start size

  private static func grid(_ json: String) throws -> RemoteTabNewGrid {
    let message = try #require(RemoteJSON.decodeInbound(Data(json.utf8)))
    return RemoteTabNewGrid.resolve(cols: message.cols, rows: message.rows, fallback: RemoteHostRouter.newTabGrid)
  }

  private static let defaultCap = RemoteTabNewGrid(columns: 120, rows: 40, exact: false)

  @Test func aRequestedSizeIsDecodedAndTakenExactly() throws {
    let message = try #require(
      RemoteJSON.decodeInbound(Data(#"{"t":"tab.new","id":4,"worktreeId":"w","cols":80,"rows":24}"#.utf8)))
    #expect(message.worktreeId == "w")
    #expect(message.cols == RemoteLenientInt(80))
    #expect(message.rows == RemoteLenientInt(24))
    #expect(
      try Self.grid(#"{"t":"tab.new","id":4,"worktreeId":"w","cols":80,"rows":24}"#)
        == RemoteTabNewGrid(columns: 80, rows: 24, exact: true))
  }

  @Test func noSizeKeepsTheDefaultCap() throws {
    #expect(try Self.grid(#"{"t":"tab.new","id":4,"worktreeId":"w"}"#) == Self.defaultCap)
  }

  @Test func onlyOneOfColsAndRowsKeepsTheDefaultCap() throws {
    #expect(try Self.grid(#"{"t":"tab.new","id":4,"worktreeId":"w","cols":80}"#) == Self.defaultCap)
    #expect(try Self.grid(#"{"t":"tab.new","id":4,"worktreeId":"w","rows":24}"#) == Self.defaultCap)
  }

  @Test func aSizeThatIsNotAnIntegerKeepsTheRequestAndTheDefaultCap() throws {
    // A bad optional field must not drop the whole request.
    let message = try #require(
      RemoteJSON.decodeInbound(Data(#"{"t":"tab.new","id":4,"worktreeId":"w","cols":"80","rows":24}"#.utf8)))
    #expect(message.t == "tab.new")
    #expect(message.id == 4)
    #expect(message.worktreeId == "w")
    #expect(try Self.grid(#"{"t":"tab.new","id":4,"worktreeId":"w","cols":"80","rows":24}"#) == Self.defaultCap)
    #expect(try Self.grid(#"{"t":"tab.new","id":4,"worktreeId":"w","cols":80.5,"rows":24}"#) == Self.defaultCap)
    #expect(try Self.grid(#"{"t":"tab.new","id":4,"worktreeId":"w","cols":80,"rows":null}"#) == Self.defaultCap)
    #expect(try Self.grid(#"{"t":"tab.new","id":4,"worktreeId":"w","cols":80,"rows":true}"#) == Self.defaultCap)
    #expect(try Self.grid(#"{"t":"tab.new","id":4,"worktreeId":"w","cols":[80],"rows":24}"#) == Self.defaultCap)
  }

  @Test func aRequestedSizeIsClampedToTheHostLimits() {
    func resolve(_ cols: Int, _ rows: Int) -> RemoteTabNewGrid {
      RemoteTabNewGrid.resolve(
        cols: RemoteLenientInt(cols), rows: RemoteLenientInt(rows), fallback: RemoteHostRouter.newTabGrid)
    }
    #expect(resolve(19, 4) == RemoteTabNewGrid(columns: 20, rows: 5, exact: true))
    #expect(resolve(20, 5) == RemoteTabNewGrid(columns: 20, rows: 5, exact: true))
    #expect(resolve(500, 200) == RemoteTabNewGrid(columns: 500, rows: 200, exact: true))
    #expect(resolve(501, 201) == RemoteTabNewGrid(columns: 500, rows: 200, exact: true))
    #expect(resolve(0, -3) == RemoteTabNewGrid(columns: 20, rows: 5, exact: true))
    #expect(resolve(10_000, 10_000) == RemoteTabNewGrid(columns: 500, rows: 200, exact: true))
  }

  // MARK: - Start grid at creation (ТД1)

  @Test func theResolvedGridIsTheTerminalsStartGrid() throws {
    #expect(
      try Self.grid(#"{"t":"tab.new","id":4,"worktreeId":"w","cols":80,"rows":24}"#).startGrid
        == TerminalStartGrid(columns: 80, rows: 24, exact: true))
    #expect(
      try Self.grid(#"{"t":"tab.new","id":4,"worktreeId":"w"}"#).startGrid
        == TerminalStartGrid(columns: 120, rows: 40, exact: false))
  }

  @Test func aStartGridIsMeasuredOnTheSourcesCellsAndPadding() {
    // A source of 250 × 70 cells of 8 × 16 px plus a 6 px padding remainder.
    let current = CGSize(width: 250 * 8 + 6, height: 70 * 16 + 6)
    let cell = CGSize(width: 8, height: 16)
    let exact = GhosttySurfaceView.GridCap.startBackingSize(
      current: current, grid: (250, 70), cell: cell, limit: (80, 24), exact: true)
    #expect(exact == CGSize(width: 80 * 8 + 6, height: 24 * 16 + 6))
    let grown = GhosttySurfaceView.GridCap.startBackingSize(
      current: current, grid: (250, 70), cell: cell, limit: (300, 90), exact: true)
    #expect(grown == CGSize(width: 300 * 8 + 6, height: 90 * 16 + 6))
    // The default cap only shrinks: a source already inside it starts as is.
    let capped = GhosttySurfaceView.GridCap.startBackingSize(
      current: current, grid: (250, 70), cell: cell, limit: (120, 40), exact: false)
    #expect(capped == CGSize(width: 120 * 8 + 6, height: 40 * 16 + 6))
    let small = CGSize(width: 100 * 8 + 6, height: 30 * 16 + 6)
    let fitting = GhosttySurfaceView.GridCap.startBackingSize(
      current: small, grid: (100, 30), cell: cell, limit: (120, 40), exact: false)
    #expect(fitting == small)
    let same = GhosttySurfaceView.GridCap.startBackingSize(
      current: small, grid: (100, 30), cell: cell, limit: (100, 30), exact: true)
    #expect(same == small)
  }

  @Test func aSourceWithoutCellMetricsGivesNoStartSize() {
    let unmeasured = GhosttySurfaceView.GridCap.startBackingSize(
      current: CGSize(width: 3200, height: 1800), grid: (0, 0), cell: .zero, limit: (80, 24), exact: true)
    #expect(unmeasured == nil)
  }

  @Test func aStartGeometryKeepsExactPixelsAndRejectsAbsurdOnes() {
    let geometry = ContentGeometry.sized(pixelSize: CGSize(width: 646, height: 390), scale: 2)
    #expect(geometry?.pixelSize == CGSize(width: 646, height: 390))
    #expect(geometry?.scale == 2)
    #expect(ContentGeometry.sized(pixelSize: CGSize(width: 0, height: 390), scale: 2) == nil)
    #expect(ContentGeometry.sized(pixelSize: CGSize(width: 646, height: 390), scale: 0) == nil)
    #expect(ContentGeometry.sized(pixelSize: CGSize(width: 40_000, height: 390), scale: 2) == nil)
    #expect(ContentGeometry.sized(pixelSize: CGSize(width: CGFloat.infinity, height: 390), scale: 2) == nil)
  }

  @Test func onlyASurfaceWithTheSourcesFontIsMeasuredOnIt() {
    // Inherits the source's font (window-inherit-font-size).
    #expect(
      TerminalSurfaceRecipe.sharesSourceFont(fontFromSource: true, plannedFontSize: 15, sourceZoomedFontSize: 15))
    #expect(
      TerminalSurfaceRecipe.sharesSourceFont(fontFromSource: true, plannedFontSize: 13, sourceZoomedFontSize: 0))
    // Both at the configured default.
    #expect(
      TerminalSurfaceRecipe.sharesSourceFont(fontFromSource: false, plannedFontSize: nil, sourceZoomedFontSize: 0))
    // The source is zoomed, the new surface is not.
    #expect(
      !TerminalSurfaceRecipe.sharesSourceFont(fontFromSource: false, plannedFontSize: nil, sourceZoomedFontSize: 18))
    // A remembered zoom the source may not have.
    #expect(
      !TerminalSurfaceRecipe.sharesSourceFont(fontFromSource: false, plannedFontSize: 18, sourceZoomedFontSize: 0))
    // No live source.
    #expect(
      !TerminalSurfaceRecipe.sharesSourceFont(fontFromSource: true, plannedFontSize: 15, sourceZoomedFontSize: nil))
  }

  @Test func aLocalWorktreeTabStartsInTheWorktreeDirectory() {
    let local = Worktree(
      location: .local(
        workingDirectory: URL(filePath: "/Users/x/repo/wt", directoryHint: .isDirectory),
        repositoryRoot: URL(filePath: "/Users/x/repo", directoryHint: .isDirectory)),
      kind: .git, name: "wt", detail: "")
    #expect(RemoteSnapshotSource.newTabDirectory(for: local)?.hasPrefix("/Users/x/repo/wt") == true)
    let remote = Worktree(
      location: .remote(RemoteHost(alias: "devbox"), workingDirectory: "/home/me/wt", repositoryRoot: "/home/me"),
      kind: .git, name: "wt", detail: "")
    #expect(RemoteSnapshotSource.newTabDirectory(for: remote) == nil)
  }

  @Test func aTabAlreadyListedAnswersWithoutWaitingForTheClock() async {
    let clock = TestClock()
    let content = UUID()
    let found = await RemoteHostRouter.poll(every: .milliseconds(100), within: .seconds(10), clock: clock) {
      content
    }
    #expect(found == content)
  }

  @Test func aTabThatAppearsBeforeTheDeadlineIsReturned() async {
    let clock = TestClock()
    let content = UUID()
    let probes = LockIsolated(0)
    let wait = Task { @MainActor in
      await RemoteHostRouter.poll(every: .milliseconds(100), within: .seconds(10), clock: clock) { () -> UUID? in
        probes.withValue { $0 += 1 }
        return probes.value >= 4 ? content : nil
      }
    }
    await Task.megaYield()
    await clock.advance(by: .milliseconds(300))
    #expect(await wait.value == content)
    #expect(probes.value == 4)
  }

  @Test func aTabThatNeverAppearsGivesUpAtTheDeadline() async {
    let clock = TestClock()
    let wait = Task { @MainActor in
      await RemoteHostRouter.poll(
        every: .milliseconds(100), within: RemoteHostRouter.tabNewTimeout, clock: clock
      ) { () -> UUID? in nil }
    }
    await Task.megaYield()
    await clock.advance(by: RemoteHostRouter.tabNewTimeout)
    #expect(await wait.value == nil)
  }

  @Test func aCancelledWaitGivesUp() async {
    let clock = TestClock()
    let wait = Task { @MainActor in
      await RemoteHostRouter.poll(every: .milliseconds(100), within: .seconds(10), clock: clock) { () -> UUID? in
        nil
      }
    }
    await Task.megaYield()
    wait.cancel()
    #expect(await wait.value == nil)
  }
}
