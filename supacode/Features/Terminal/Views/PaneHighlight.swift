import ComposableArchitecture
import SwiftUI

/// Fork (РС4, РС5): the accent border of the focused pane in a split, and the flash that marks the
/// pane a close confirmation is about, first without the dialog and then while it shows. View-only:
/// the main and remote windows read the pending confirmation their reducers already hold
/// (`LayoutFeature.State.alertPaneID`, the remote Close Tab alert); no reducer state is added.
nonisolated enum PaneHighlight {
  /// The steady border of the focused pane in a split.
  static let focusBorderWidth: CGFloat = 2
  /// The flashing border of a close confirmation's pane: a little heavier, so it reads as an alert.
  static let flashBorderWidth: CGFloat = 3
  /// How long one lit or dark step of a pulse lasts.
  static let pulseOn: Duration = .milliseconds(160)
  static let pulseOff: Duration = .milliseconds(120)
  /// The fade between a lit and a dark step.
  static let pulseFade: Double = 0.08
  /// Pulses before the dialog appears, and pulses while it shows; the border then stays lit.
  static let pulsesBeforeDialog = 2
  static let pulsesWithDialog = 3

  nonisolated struct FlashStep: Equatable, Sendable {
    let isLit: Bool
    let duration: Duration
  }

  /// РС4: only the focused pane of a view that shows more than one pane. A single pane, or the
  /// one pane a zoomed split shows, is always the working one and gets no border.
  static func showsFocusBorder(isFocused: Bool, isSplit: Bool, isZoomed: Bool) -> Bool {
    isFocused && isSplit && !isZoomed
  }

  /// РС5: the flash, lit first. With Reduce Motion there is no pulse: the border just stays lit
  /// while the dialog is up.
  static func flashSteps(reduceMotion: Bool) -> [FlashStep] {
    guard !reduceMotion else { return [] }
    let pulse = [FlashStep(isLit: true, duration: pulseOn), FlashStep(isLit: false, duration: pulseOff)]
    return Array(repeating: pulse, count: pulsesBeforeDialog + pulsesWithDialog).flatMap { $0 }
  }

  /// How long a close confirmation waits for the pulses before the dialog; none with Reduce Motion.
  static func dialogDelay(reduceMotion: Bool) -> Duration {
    reduceMotion ? .zero : (pulseOn + pulseOff) * pulsesBeforeDialog
  }

  /// Whether the dialog of `heldAlertID` (a confirmation whose pane flashes on screen) still waits.
  /// Keyed by the alert's id, so every new confirmation waits again.
  static func isDialogHeld(heldAlertID: UUID?, releasedAlertID: UUID?, reduceMotion: Bool) -> Bool {
    guard let heldAlertID, !reduceMotion else { return false }
    return releasedAlertID != heldAlertID
  }
}

/// The accent border a pane draws over itself: steady on the focused pane of a split (РС4),
/// pulsing while a close confirmation targets the pane (РС5); the flash wins over the steady
/// border, so a focused pane still visibly flashes. An overlay only: the pane's size, and so a
/// terminal's grid, never changes.
struct PaneHighlightBorder: View {
  let showsFocusBorder: Bool
  /// The id of the pending close confirmation this pane is the target of.
  let flashID: UUID?

  @State private var isFlashLit = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      if let flashID {
        Rectangle()
          .strokeBorder(Color.accentColor, lineWidth: PaneHighlight.flashBorderWidth)
          .opacity(isFlashLit ? 1 : 0)
          .task(id: flashID) { await flash() }
      } else if showsFocusBorder {
        Rectangle()
          .strokeBorder(Color.accentColor, lineWidth: PaneHighlight.focusBorderWidth)
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func flash() async {
    isFlashLit = true
    for step in PaneHighlight.flashSteps(reduceMotion: reduceMotion) {
      withAnimation(.easeInOut(duration: PaneHighlight.pulseFade)) { isFlashLit = step.isLit }
      do { try await Task.sleep(for: step.duration) } catch { return }
    }
    withAnimation(.easeInOut(duration: PaneHighlight.pulseFade)) { isFlashLit = true }
  }
}

extension View {
  /// Presents a store-driven alert like `.alert(_:)`, holding back a close confirmation whose pane
  /// flashes on screen (`heldAlertID`) for the pulses before the dialog (РС5). A nil
  /// `heldAlertID` presents at once.
  func paneCloseConfirmationAlert<Action>(
    _ alert: Binding<Store<AlertState<Action>, Action>?>,
    heldAlertID: UUID?
  ) -> some View {
    modifier(PaneCloseConfirmationAlert(alert: alert, heldAlertID: heldAlertID))
  }
}

private struct PaneCloseConfirmationAlert<Action>: ViewModifier {
  let alert: Binding<Store<AlertState<Action>, Action>?>
  let heldAlertID: UUID?

  @State private var releasedAlertID: UUID?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    let isHeld = PaneHighlight.isDialogHeld(
      heldAlertID: heldAlertID, releasedAlertID: releasedAlertID, reduceMotion: reduceMotion)
    content
      .alert(isHeld ? .constant(nil) : alert)
      .task(id: heldAlertID) {
        guard let heldAlertID else { return }
        do { try await Task.sleep(for: PaneHighlight.dialogDelay(reduceMotion: reduceMotion)) } catch { return }
        releasedAlertID = heldAlertID
      }
  }
}
