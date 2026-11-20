import Clocks
import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import SupacodeSettingsShared
import Testing

@testable import supacode

/// НП4: ⌘ or ⌃ held alone shows the shortcut hints after a moment; a chord never flashes them.
struct ShortcutHintHoldGateTests {
  typealias Gate = ShortcutHintHoldGate

  @Test func aModifierHeldAloneShowsTheHintsAfterTheHold() {
    var gate = Gate()
    let generation = gate.modifiersChanged(held: true)
    #expect(generation != nil)
    #expect(!gate.isShowing)
    #expect(gate.isWaiting)
    gate.holdElapsed(generation: generation ?? -1)
    #expect(gate.isShowing)
  }

  @Test func releaseHidesTheHintsAtOnce() {
    var gate = Gate()
    let generation = gate.modifiersChanged(held: true) ?? -1
    gate.holdElapsed(generation: generation)
    let none = gate.modifiersChanged(held: false)
    #expect(none == nil)
    #expect(!gate.isShowing)
    #expect(gate.phase == .idle)
  }

  @Test func aReleaseBeforeTheHoldEndsShowsNothing() {
    var gate = Gate()
    let generation = gate.modifiersChanged(held: true) ?? -1
    _ = gate.modifiersChanged(held: false)
    gate.holdElapsed(generation: generation)
    #expect(!gate.isShowing)
  }

  @Test func aChordNeverShowsTheHints() {
    // ⌃C in a terminal: the key comes before the hold ends.
    var gate = Gate()
    let generation = gate.modifiersChanged(held: true) ?? -1
    gate.keyPressed()
    gate.holdElapsed(generation: generation)
    #expect(!gate.isShowing)
    #expect(gate.phase == .chorded)
    // Still held after the chord: no new hold starts, the hints stay hidden until release.
    let again = gate.modifiersChanged(held: true)
    #expect(again == nil)
    #expect(!gate.isShowing)
  }

  @Test func aKeyHidesShownHintsUntilBothModifiersAreReleased() {
    var gate = Gate()
    gate.holdElapsed(generation: gate.modifiersChanged(held: true) ?? -1)
    #expect(gate.isShowing)
    // ⌘2 picks a tab: the hints go at once.
    gate.keyPressed()
    #expect(!gate.isShowing)
    // Released and held again: a new hold, the hints come back.
    _ = gate.modifiersChanged(held: false)
    let next = gate.modifiersChanged(held: true) ?? -1
    gate.holdElapsed(generation: next)
    #expect(gate.isShowing)
  }

  @Test func aStaleHoldDoesNotShowTheHints() {
    var gate = Gate()
    let first = gate.modifiersChanged(held: true) ?? -1
    _ = gate.modifiersChanged(held: false)
    let second = gate.modifiersChanged(held: true) ?? -1
    #expect(first != second)
    gate.holdElapsed(generation: first)
    #expect(!gate.isShowing)
    gate.holdElapsed(generation: second)
    #expect(gate.isShowing)
  }

  @Test func addingAModifierNeitherRestartsTheHoldNorHidesTheHints() {
    var gate = Gate()
    let generation = gate.modifiersChanged(held: true) ?? -1
    // ⇧ added while ⌘ is held: still held.
    let added = gate.modifiersChanged(held: true)
    #expect(added == nil)
    gate.holdElapsed(generation: generation)
    #expect(gate.isShowing)
    let stillShowing = gate.modifiersChanged(held: true)
    #expect(stillShowing == nil)
    #expect(gate.isShowing)
  }

  @Test func typingWithoutAModifierChangesNothing() {
    var gate = Gate()
    gate.keyPressed()
    #expect(gate.phase == .idle)
  }

  @Test func activatingWithAModifierDownCountsAsAChord() {
    // ⌘⇥ into the app with ⌘ still down.
    var gate = Gate()
    gate.activated(held: true)
    #expect(gate.phase == .chorded)
    let none = gate.modifiersChanged(held: true)
    #expect(none == nil)
    #expect(!gate.isShowing)
    gate.activated(held: false)
    #expect(gate.phase == .idle)
  }

  // MARK: - CommandKeyObserver wiring

  @MainActor
  @Test(.dependencies) func theObserverShowsTheHintsOnlyAfterTheHoldOnItsClock() async {
    await withDependencies {
      $0.settingsFileStorage = SettingsTestStorage().storage
      $0.settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-hold-\(UUID().uuidString).json")
    } operation: {
      let clock = TestClock()
      let observer = CommandKeyObserver(clock: clock)

      observer.handleCommandKeyChange(isDown: true)
      #expect(!observer.isPressed)
      // Short of the hold: still hidden.
      await clock.advance(by: .milliseconds(100))
      #expect(!observer.isPressed)
      let shown = await RemoteRouterTestSupport.step(
        clock, until: { observer.isPressed }, within: .seconds(2), increment: .milliseconds(50))
      #expect(shown)

      // A key pressed with the modifier hides them at once and they stay hidden.
      observer.handleKeyDown()
      #expect(!observer.isPressed)
      await RemoteRouterTestSupport.step(clock, by: .seconds(1), increment: .milliseconds(100))
      #expect(!observer.isPressed)

      observer.handleCommandKeyChange(isDown: false)
      #expect(!observer.isPressed)
    }
  }

  @MainActor
  @Test(.dependencies) func aChordBeforeTheHoldNeverShowsTheHints() async {
    await withDependencies {
      $0.settingsFileStorage = SettingsTestStorage().storage
      $0.settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-hold-\(UUID().uuidString).json")
    } operation: {
      let clock = TestClock()
      let observer = CommandKeyObserver(clock: clock)

      observer.handleCommandKeyChange(isDown: true)
      observer.handleKeyDown()
      await RemoteRouterTestSupport.step(clock, by: .seconds(1), increment: .milliseconds(100))
      #expect(!observer.isPressed)
    }
  }
}
