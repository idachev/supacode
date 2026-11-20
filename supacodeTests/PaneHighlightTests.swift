import Foundation
import Testing

@testable import supacode

/// РС4 / РС5: the focused-pane border rule and the close confirmation's flash schedule.
struct PaneHighlightTests {
  // MARK: - Focus border (РС4)

  @Test func onlyTheFocusedPaneOfAnUnzoomedSplitHasTheBorder() {
    #expect(PaneHighlight.showsFocusBorder(isFocused: true, isSplit: true, isZoomed: false))
    #expect(!PaneHighlight.showsFocusBorder(isFocused: false, isSplit: true, isZoomed: false))
  }

  @Test func aSinglePaneHasNoBorder() {
    #expect(!PaneHighlight.showsFocusBorder(isFocused: true, isSplit: false, isZoomed: false))
  }

  @Test func aZoomedSplitShowsOnePaneAndHasNoBorder() {
    #expect(!PaneHighlight.showsFocusBorder(isFocused: true, isSplit: true, isZoomed: true))
  }

  // MARK: - Flash (РС5)

  @Test func theFlashPulsesBeforeAndWithTheDialog() {
    let steps = PaneHighlight.flashSteps(reduceMotion: false)
    let pulses = PaneHighlight.pulsesBeforeDialog + PaneHighlight.pulsesWithDialog
    #expect(steps.count == pulses * 2)
    // Lit first, then alternating, so every pulse is one lit and one dark step.
    for (index, step) in steps.enumerated() {
      #expect(step.isLit == index.isMultiple(of: 2))
    }
    #expect((1...2).contains(PaneHighlight.pulsesBeforeDialog))
    #expect((2...3).contains(PaneHighlight.pulsesWithDialog))
  }

  @Test func theDialogWaitsForThePulsesBeforeIt() {
    let delay = PaneHighlight.dialogDelay(reduceMotion: false)
    let steps = PaneHighlight.flashSteps(reduceMotion: false)
    let beforeDialog = steps.prefix(PaneHighlight.pulsesBeforeDialog * 2).reduce(Duration.zero) { $0 + $1.duration }
    #expect(delay == beforeDialog)
    #expect(delay >= .milliseconds(400) && delay <= .milliseconds(600))
    let total = steps.reduce(Duration.zero) { $0 + $1.duration }
    #expect(total >= .milliseconds(1200) && total <= .milliseconds(1700))
  }

  @Test func reduceMotionHasNoPulseAndNoDelay() {
    #expect(PaneHighlight.flashSteps(reduceMotion: true).isEmpty)
    #expect(PaneHighlight.dialogDelay(reduceMotion: true) == .zero)
  }

  @Test func aHeldConfirmationWaitsUntilItsOwnReleaseOnly() {
    let first = UUID()
    let second = UUID()
    #expect(PaneHighlight.isDialogHeld(heldAlertID: first, releasedAlertID: nil, reduceMotion: false))
    #expect(!PaneHighlight.isDialogHeld(heldAlertID: first, releasedAlertID: first, reduceMotion: false))
    // A new confirmation waits again even though an earlier one was released.
    #expect(PaneHighlight.isDialogHeld(heldAlertID: second, releasedAlertID: first, reduceMotion: false))
  }

  @Test func anAlertWithoutAFlashingPaneOrUnderReduceMotionIsNotHeld() {
    #expect(!PaneHighlight.isDialogHeld(heldAlertID: nil, releasedAlertID: nil, reduceMotion: false))
    #expect(!PaneHighlight.isDialogHeld(heldAlertID: UUID(), releasedAlertID: nil, reduceMotion: true))
  }
}
