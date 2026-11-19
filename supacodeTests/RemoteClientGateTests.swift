import Foundation
import Testing

@testable import supacode

struct RemoteClientGateTests {
  static let key = "abcde-fghij-klmno-pqrst-uvwxy-z2345"
  static let fpHex = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
  static let fpMac = "e1bef7bccaed983a401062bd7faa05f9fa1a1ca2315570c82009429bdde65a77"

  private static let nothing = RemoteStreamGate.Verdict(deliver: false, detach: [])
  private static let passes = RemoteStreamGate.Verdict(deliver: true, detach: [])

  // MARK: LAN trust

  @Test func theSharedVectorIsValid() {
    #expect(RemoteLANTrust.fpMacValid(clientKey: Self.key, fp: Self.fpHex, fpMac: Self.fpMac))
    #expect(RemoteLANTrust.fpMacValid(clientKey: Self.key, fp: Self.fpHex, fpMac: Self.fpMac.uppercased()))
  }

  @Test func anyDifferenceIsInvalid() {
    #expect(!RemoteLANTrust.fpMacValid(clientKey: Self.key + "-x", fp: Self.fpHex, fpMac: Self.fpMac))
    #expect(!RemoteLANTrust.fpMacValid(clientKey: Self.key, fp: Self.fpHex.uppercased(), fpMac: Self.fpMac))
    #expect(!RemoteLANTrust.fpMacValid(clientKey: Self.key, fp: Self.fpHex, fpMac: String(Self.fpMac.dropLast(2))))
    #expect(!RemoteLANTrust.fpMacValid(clientKey: Self.key, fp: Self.fpHex, fpMac: "zz" + Self.fpMac.dropFirst(2)))
    #expect(!RemoteLANTrust.fpMacValid(clientKey: Self.key, fp: "", fpMac: Self.fpMac))
    let changed = Self.fpHex.replacing("0", with: "1", maxReplacements: 1)
    #expect(!RemoteLANTrust.fpMacValid(clientKey: Self.key, fp: changed, fpMac: Self.fpMac))
    #expect(!RemoteLANTrust.fpMacValid(clientKey: Self.key, fp: Self.fpHex, fpMac: ""))
  }

  @Test func thePinComparesTheDERFingerprint() {
    let der = Data("certificate".utf8)
    #expect(RemoteLANTrust.pinMatches(der: der, fp: RemoteLANIdentity.fingerprint(der: der).uppercased()))
    #expect(!RemoteLANTrust.pinMatches(der: der, fp: Self.fpHex))
  }

  @Test func thePinMatchesTheLowerCaseFingerprintAndNotAnother() {
    let der = Data("certificate".utf8)
    let pin = RemoteLANIdentity.fingerprint(der: der)
    #expect(pin.count == 64)
    #expect(RemoteLANTrust.pinMatches(der: der, fp: pin))
    #expect(!RemoteLANTrust.pinMatches(der: Data("other".utf8), fp: pin))
    #expect(!RemoteLANTrust.pinMatches(der: der, fp: ""))
    #expect(!RemoteLANTrust.pinMatches(der: der, fp: String(pin.dropLast())))
  }

  // MARK: Stream gate

  @Test func theFirstAttachedMakesItsPathCurrent() {
    var gate = RemoteStreamGate()
    gate.attachSent(on: .relay, id: 2)
    #expect(gate.accept(from: .relay, .out) == .init(deliver: false, detach: []))
    #expect(gate.accept(from: .relay, .attached(id: 2)) == .init(deliver: true, detach: []))
    #expect(gate.accept(from: .relay, .out) == .init(deliver: true, detach: []))
  }

  @Test func aNewPathTakesOverOnlyAtItsAttached() {
    var gate = RemoteStreamGate()
    gate.attachSent(on: .relay, id: 2)
    _ = gate.accept(from: .relay, .attached(id: 2))
    gate.attachSent(on: .lan, id: 3)
    #expect(gate.accept(from: .relay, .out).deliver)  // the old stream still runs
    #expect(gate.accept(from: .lan, .out).deliver == false)
    #expect(gate.accept(from: .lan, .attached(id: 3)) == .init(deliver: true, detach: [.relay]))
    #expect(gate.accept(from: .relay, .out).deliver == false)  // late frames of the old path
  }

  @Test func anAttachedWithAnotherIdDoesNotSwitch() {
    var gate = RemoteStreamGate()
    gate.attachSent(on: .lan, id: 3)
    #expect(gate.accept(from: .lan, .attached(id: 9)).deliver == false)
    #expect(gate.current == nil)
  }

  @Test func anAttachedWithoutAnIdAnswersThePendingAttach() {
    var gate = RemoteStreamGate()
    gate.attachSent(on: .lan, id: 3)
    #expect(gate.accept(from: .lan, .attached(id: nil)) == Self.passes)
    #expect(gate.current == .lan)
  }

  @Test func aClosedCurrentPathStopsItsFrames() {
    var gate = RemoteStreamGate()
    gate.attachSent(on: .lan, id: 3)
    _ = gate.accept(from: .lan, .attached(id: 3))
    gate.closed(.lan)
    #expect(gate.current == nil)
    #expect(gate.accept(from: .lan, .out).deliver == false)
  }

  @Test func detachNamesTheOtherAttachedPaths() {
    var gate = RemoteStreamGate()
    gate.attachSent(on: .relay, id: 2)
    _ = gate.accept(from: .relay, .attached(id: 2))
    gate.attachSent(on: .lan, id: 3)
    #expect(gate.detachSent(on: .relay) == [.lan])
    #expect(gate.current == nil)
  }

  // MARK: Ported from stream-gate.test.mjs / TerminalStreamGateTest.kt

  @Test func relayOutputRunsUntilTheLANAttachAnswers() {
    var gate = attachedOnRelay()
    gate.attachSent(on: .lan, id: 2)
    #expect(gate.accept(from: .relay, .out).deliver)
    #expect(gate.accept(from: .relay, .size).deliver)
    #expect(gate.accept(from: .lan, .attached(id: 2)) == .init(deliver: true, detach: [.relay]))
  }

  @Test func afterTheLANAttachedRelayFramesAreDroppedDetachedIncluded() {
    var gate = attachedOnRelay()
    gate.attachSent(on: .lan, id: 2)
    _ = gate.accept(from: .lan, .attached(id: 2))
    #expect(gate.accept(from: .relay, .out).deliver == false)
    #expect(gate.accept(from: .relay, .size).deliver == false)
    #expect(gate.accept(from: .relay, .detached).deliver == false)
    #expect(gate.accept(from: .lan, .out).deliver)
  }

  @Test func afterTheLANClosesFramesComeBackOnlyAtTheNewAttached() {
    var gate = attachedOnRelay()
    gate.attachSent(on: .lan, id: 2)
    _ = gate.accept(from: .lan, .attached(id: 2))
    gate.closed(.lan)
    #expect(gate.accept(from: .lan, .out).deliver == false)
    gate.attachSent(on: .relay, id: 3)
    #expect(gate.accept(from: .relay, .out).deliver == false)
    #expect(gate.accept(from: .relay, .attached(id: 1)).deliver == false)
    #expect(gate.accept(from: .relay, .attached(id: 3)).deliver)
    #expect(gate.accept(from: .relay, .out).deliver)
  }

  @Test func theLANClosingBeforeItsAttachedLeavesTheRelayStreamRunning() {
    var gate = attachedOnRelay()
    gate.attachSent(on: .lan, id: 2)
    gate.closed(.lan)
    #expect(gate.accept(from: .lan, .attached(id: 2)).deliver == false)
    #expect(gate.accept(from: .relay, .out).deliver)
    #expect(gate.current == .relay)
  }

  @Test func aLateRelayAttachedAfterTheLANSwitchDoesNotTakeThePathBack() {
    var gate = RemoteStreamGate()
    gate.attachSent(on: .relay, id: 1)
    gate.attachSent(on: .lan, id: 2)
    #expect(gate.accept(from: .relay, .attached(id: 1)).deliver == false)
    #expect(gate.accept(from: .lan, .attached(id: 2)) == .init(deliver: true, detach: [.relay]))
    #expect(gate.accept(from: .relay, .out).deliver == false)
  }

  @Test func aReconnectedSocketOfTheSamePathStartsFromItsOwnAttached() {
    var gate = attachedOnRelay()
    gate.closed(.relay)
    #expect(gate.accept(from: .relay, .out).deliver == false)
    gate.attachSent(on: .relay, id: 4)
    #expect(gate.accept(from: .relay, .attached(id: 4)).deliver)
    #expect(gate.accept(from: .relay, .out).deliver)
  }

  @Test func aDetachOverTheLANAlsoStopsTheAttachLeftOnTheRelay() {
    var gate = RemoteStreamGate()
    gate.attachSent(on: .relay, id: 1)
    gate.attachSent(on: .lan, id: 2)
    #expect(gate.detachSent(on: .lan) == [.relay])
    #expect(gate.accept(from: .lan, .out).deliver == false)
  }

  @Test func aDetachOverTheOtherPathStopsTheCurrentPathToo() {
    var gate = attachedOnRelay()
    gate.attachSent(on: .lan, id: 2)
    #expect(gate.detachSent(on: .lan) == [.relay])
    #expect(gate.accept(from: .relay, .out).deliver == false)
  }

  @Test func aDetachClearsThePendingAttach() {
    var gate = RemoteStreamGate()
    gate.attachSent(on: .lan, id: 2)
    #expect(gate.detachSent(on: .lan).isEmpty)
    #expect(gate.accept(from: .lan, .attached(id: 2)) == Self.nothing)
    #expect(gate.current == nil)
  }

  @Test func theDetachedOfTheCurrentPathIsDeliveredAndForgetsItsAttach() {
    var gate = attachedOnRelay()
    #expect(gate.accept(from: .relay, .detached) == Self.passes)
    gate.attachSent(on: .lan, id: 2)
    #expect(gate.accept(from: .lan, .attached(id: 2)) == Self.passes)
  }

  @Test func anAttachedFromTheCurrentPathWithNothingPendingIsDelivered() {
    var gate = attachedOnRelay()
    #expect(gate.accept(from: .relay, .attached(id: 1)) == Self.passes)
  }

  // MARK: Helpers

  private func attachedOnRelay() -> RemoteStreamGate {
    var gate = RemoteStreamGate()
    gate.attachSent(on: .relay, id: 1)
    #expect(gate.accept(from: .relay, .attached(id: 1)).deliver)
    #expect(gate.accept(from: .relay, .out).deliver)
    return gate
  }
}
