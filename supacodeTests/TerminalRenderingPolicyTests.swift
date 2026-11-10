import SwiftUI
import Testing

@testable import supacode

@MainActor
struct TerminalRenderingPolicyTests {
  @Test func gridCapRemovesWholeCellsAndKeepsThePadding() {
    // 403 × 110 cells of 8 × 16 px plus a 6 px padding remainder on each axis.
    let capped = GhosttySurfaceView.GridCap.backingSize(
      current: CGSize(width: 403 * 8 + 6, height: 110 * 16 + 6),
      grid: (403, 110), cell: CGSize(width: 8, height: 16), limit: (120, 40))
    #expect(capped == CGSize(width: 120 * 8 + 6, height: 40 * 16 + 6))
  }

  @Test func gridCapShrinksOnlyTheAxisThatIsTooBig() {
    let capped = GhosttySurfaceView.GridCap.backingSize(
      current: CGSize(width: 1606, height: 486),
      grid: (200, 30), cell: CGSize(width: 8, height: 16), limit: (120, 40))
    #expect(capped == CGSize(width: 966, height: 486))
  }

  @Test func gridCapLeavesAFittingOrUnmeasuredGridAlone() {
    let fitting = GhosttySurfaceView.GridCap.backingSize(
      current: CGSize(width: 806, height: 486),
      grid: (100, 30), cell: CGSize(width: 8, height: 16), limit: (120, 40))
    #expect(fitting == nil)
    let unmeasured = GhosttySurfaceView.GridCap.backingSize(
      current: CGSize(width: 3200, height: 1800),
      grid: (403, 110), cell: CGSize(width: 0, height: 0), limit: (120, 40))
    #expect(unmeasured == nil)
  }

  @Test func anExactGridGrowsByWholeCellsAndKeepsThePadding() {
    // 80 × 24 cells of 8 × 16 px plus a 6 px padding remainder, asked for 200 × 60.
    let sized = GhosttySurfaceView.GridCap.backingSize(
      current: CGSize(width: 80 * 8 + 6, height: 24 * 16 + 6),
      grid: (80, 24), cell: CGSize(width: 8, height: 16), limit: (200, 60), exact: true)
    #expect(sized == CGSize(width: 200 * 8 + 6, height: 60 * 16 + 6))
  }

  @Test func anExactGridGrowsOneAxisAndShrinksTheOther() {
    let sized = GhosttySurfaceView.GridCap.backingSize(
      current: CGSize(width: 403 * 8 + 6, height: 24 * 16 + 6),
      grid: (403, 24), cell: CGSize(width: 8, height: 16), limit: (100, 50), exact: true)
    #expect(sized == CGSize(width: 100 * 8 + 6, height: 50 * 16 + 6))
  }

  @Test func anExactGridLeavesAMatchingOrUnmeasuredGridAlone() {
    let matching = GhosttySurfaceView.GridCap.backingSize(
      current: CGSize(width: 806, height: 486),
      grid: (100, 30), cell: CGSize(width: 8, height: 16), limit: (100, 30), exact: true)
    #expect(matching == nil)
    let unmeasured = GhosttySurfaceView.GridCap.backingSize(
      current: CGSize(width: 640, height: 384),
      grid: (80, 24), cell: CGSize(width: 0, height: 0), limit: (200, 60), exact: true)
    #expect(unmeasured == nil)
  }

  @Test func theDefaultCapNeverGrowsASmallGrid() {
    let capped = GhosttySurfaceView.GridCap.backingSize(
      current: CGSize(width: 80 * 8 + 6, height: 24 * 16 + 6),
      grid: (80, 24), cell: CGSize(width: 8, height: 16), limit: (120, 40))
    #expect(capped == nil)
  }

  @Test func resizeSkipsOnlySizesThatWereActuallyApplied() {
    let applied = CGSize(width: 1600, height: 1200)
    let decision = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: applied,
      lastAppliedBackingSize: applied,
      cellWidth: 10,
      cellHeight: 20
    )
    #expect(decision == .skipUnchanged)
  }

  @Test func resizeRejectsDegenerateGridWithoutRecordingIt() {
    let degenerate = CGSize(width: 48, height: 30)
    let decision = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: degenerate,
      lastAppliedBackingSize: CGSize(width: 1600, height: 1200),
      cellWidth: 10,
      cellHeight: 20
    )
    #expect(decision == .rejectDegenerate)
  }

  @Test func resizeBackToPreviouslyRejectedSizeAppliesOnceGridIsViable() {
    // Regression: the old code recorded a rejected size as applied, so a later
    // legitimate resize to the same backing size was skipped forever.
    let size = CGSize(width: 48, height: 40)
    let lastApplied = CGSize(width: 1600, height: 1200)
    let rejected = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: size,
      lastAppliedBackingSize: lastApplied,
      cellWidth: 10,
      cellHeight: 20
    )
    #expect(rejected == .rejectDegenerate)
    let retried = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: size,
      lastAppliedBackingSize: lastApplied,
      cellWidth: 8,
      cellHeight: 16
    )
    #expect(retried == .apply)
  }

  @Test func resizeWithUnknownCellMetricsAlwaysApplies() {
    let decision = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: CGSize(width: 2, height: 2),
      lastAppliedBackingSize: .zero,
      cellWidth: 0,
      cellHeight: 0
    )
    #expect(decision == .apply)
  }

  @Test func resizeWithOnlyOneUnknownCellDimensionStillApplies() {
    // Each half of the cell-metric guard must independently short-circuit, or the
    // divisions below it would divide by zero.
    let unknownHeight = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: CGSize(width: 800, height: 600),
      lastAppliedBackingSize: .zero,
      cellWidth: 10,
      cellHeight: 0
    )
    #expect(unknownHeight == .apply)
    let unknownWidth = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: CGSize(width: 800, height: 600),
      lastAppliedBackingSize: .zero,
      cellWidth: 0,
      cellHeight: 20
    )
    #expect(unknownWidth == .apply)
  }

  @Test func resizeRejectsWhenOnlyColumnsAreBelowMinimum() {
    let decision = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: CGSize(width: 49, height: 100),
      lastAppliedBackingSize: .zero,
      cellWidth: 10,
      cellHeight: 20
    )
    #expect(decision == .rejectDegenerate)
  }

  @Test func resizeRejectsWhenOnlyRowsAreBelowMinimum() {
    let decision = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: CGSize(width: 100, height: 39),
      lastAppliedBackingSize: .zero,
      cellWidth: 10,
      cellHeight: 20
    )
    #expect(decision == .rejectDegenerate)
  }

  @Test func resizeAppliesAtExactMinimumGrid() {
    let decision = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: CGSize(width: 50, height: 40),
      lastAppliedBackingSize: .zero,
      cellWidth: 10,
      cellHeight: 20
    )
    #expect(decision == .apply)
  }

}
