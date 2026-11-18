import Clocks
import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

/// `resize` with `hold` (ПТ6): the owner bookkeeping (`RemoteGridHolds`), then
/// the router with fake zmx streams (`RemoteRouterHarness`). The harness has no
/// live terminal, so `pinGrid` / `unpinGrid` cannot be observed there; the
/// router tests check the holds the router keeps (`heldGrids`, `orphanedHolds`).
/// A held resize in the harness ends in `resize_failed` after
/// `RemoteHostRouter.resizeReadyTimeout` (no surface ever gets ready).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RemoteAccessGridHoldTests {
  static let tab = UUID()

  @Test func theLastHoldingRequestOwnsTheSize() {
    var holds = RemoteGridHolds()
    holds.take(contentID: Self.tab, connID: "c1", columns: 100, rows: 30)
    holds.take(contentID: Self.tab, connID: "c2", columns: 120, rows: 40)
    #expect(holds.byContent[Self.tab] == .init(owner: "c2", columns: 120, rows: 40))
  }

  @Test func onlyTheOwnersDetachEndsTheHold() {
    var holds = RemoteGridHolds()
    holds.take(contentID: Self.tab, connID: "c1", columns: 100, rows: 30)
    let byOther = holds.ownerDetached(contentID: Self.tab, connID: "c2")
    #expect(!byOther)
    let byOwner = holds.ownerDetached(contentID: Self.tab, connID: "c1")
    #expect(byOwner)
    #expect(holds.byContent.isEmpty)
  }

  @Test func aLostConnectionKeepsTheHoldForItsGrace() {  // РФ5
    var holds = RemoteGridHolds()
    holds.take(contentID: Self.tab, connID: "c1", columns: 100, rows: 30)
    let orphaned = holds.ownerLost(connID: "c1", contentID: nil)
    #expect(orphaned == [Self.tab])
    #expect(holds.byContent[Self.tab] == .init(owner: nil, columns: 100, rows: 30))
    // A new connection takes it over inside the 30 s: the timer then ends nothing.
    holds.take(contentID: Self.tab, connID: "c2", columns: 100, rows: 30)
    let expired = holds.graceExpired(contentID: Self.tab)
    #expect(!expired)
    #expect(holds.byContent[Self.tab]?.owner == "c2")
  }

  @Test func theGraceEndsAnOrphanedHold() {
    var holds = RemoteGridHolds()
    holds.take(contentID: Self.tab, connID: "c1", columns: 100, rows: 30)
    _ = holds.ownerLost(connID: "c1", contentID: nil)
    let expired = holds.graceExpired(contentID: Self.tab)
    #expect(expired)
    #expect(holds.byContent.isEmpty)
  }

  @Test func losingOneStreamOrphansOnlyThatContent() {
    var holds = RemoteGridHolds()
    let other = UUID()
    holds.take(contentID: Self.tab, connID: "c1", columns: 100, rows: 30)
    holds.take(contentID: other, connID: "c1", columns: 80, rows: 24)
    #expect(holds.ownerLost(connID: "c1", contentID: other) == [other])
    #expect(holds.byContent[Self.tab]?.owner == "c1")
  }

  @Test func aLostConnectionThatOwnsNothingChangesNothing() {
    var holds = RemoteGridHolds()
    holds.take(contentID: Self.tab, connID: "c1", columns: 100, rows: 30)
    #expect(holds.ownerLost(connID: "c2", contentID: nil).isEmpty)
  }

  @Test func aPlainResizeEndsTheHold() {
    var holds = RemoteGridHolds()
    holds.take(contentID: Self.tab, connID: "c1", columns: 100, rows: 30)
    let ended = holds.drop(contentID: Self.tab)
    #expect(ended)
  }

  @Test func aDropOrExpiryOfNoHoldEndsNothing() {
    var holds = RemoteGridHolds()
    let dropped = holds.drop(contentID: Self.tab)
    #expect(!dropped)
    let expired = holds.graceExpired(contentID: Self.tab)
    #expect(!expired)
    holds.take(contentID: Self.tab, connID: "c1", columns: 100, rows: 30)
    // Still owned: the grace of an earlier loss must not end it.
    let ownedExpired = holds.graceExpired(contentID: Self.tab)
    #expect(!ownedExpired)
    #expect(holds.byContent[Self.tab]?.owner == "c1")
  }

  @Test func onlyTheRequestsOwnHoldMayStillPin() {  // review F1
    var holds = RemoteGridHolds()
    #expect(!holds.allowsPin(contentID: Self.tab, connID: "c1", columns: 100, rows: 30))
    holds.take(contentID: Self.tab, connID: "c1", columns: 100, rows: 30)
    #expect(holds.allowsPin(contentID: Self.tab, connID: "c1", columns: 100, rows: 30))
    // Another size or another owner: a newer request's hold.
    #expect(!holds.allowsPin(contentID: Self.tab, connID: "c1", columns: 120, rows: 30))
    #expect(!holds.allowsPin(contentID: Self.tab, connID: "c2", columns: 100, rows: 30))
    // Its own hold in the grace after its stream closed still pins.
    _ = holds.ownerLost(connID: "c1", contentID: Self.tab)
    #expect(holds.allowsPin(contentID: Self.tab, connID: "c1", columns: 100, rows: 30))
    _ = holds.drop(contentID: Self.tab)
    #expect(!holds.allowsPin(contentID: Self.tab, connID: "c1", columns: 100, rows: 30))
  }

  // MARK: - Router

  private static func attach(_ contentID: UUID, keep: Bool) -> String {
    #"{"t":"attach","id":1,"contentId":"\#(contentID.uuidString)","keep":\#(keep)}"#
  }

  private static func resize(
    _ contentID: UUID, id: Int = 5, cols: Int = 100, rows: Int = 30, hold: Bool
  ) -> String {
    let holdField = hold ? #","hold":true"# : ""
    return
      #"{"t":"resize","id":\#(id),"contentId":"\#(contentID.uuidString)","cols":\#(cols),"rows":\#(rows)\#(holdField)}"#
  }

  @Test func aHeldResizeSupersededInTheSameTurnLeavesNoHoldAndNoReply() async {  // review F1
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock)
    defer { harness.router.stop() }
    let tab = harness.contents[0]
    let phone = harness.openPhone("phone-1")
    harness.send("phone-1", Self.attach(tab, keep: true))
    harness.send("phone-1", Self.resize(tab, id: 7, hold: true))
    harness.send("phone-1", Self.resize(tab, id: 8, cols: 90, rows: 25, hold: false))
    #expect(harness.router.heldGrids.isEmpty)
    // Both waits would end by `resizeReadyTimeout` (no surface ever gets ready);
    // only the plain one is still waiting, so only it answers.
    let answered = await Self.step(
      clock, until: { !phone.messages(ofType: "error").isEmpty },
      within: RemoteHostRouter.resizeReadyTimeout + .seconds(2))
    #expect(answered)
    await Self.step(clock, by: .seconds(1))
    #expect(phone.messages(ofType: "error").compactMap { $0["id"] as? Int } == [8])
    #expect(harness.router.heldGrids.isEmpty)
    #expect(harness.router.orphanedHolds.isEmpty)
  }

  /// Moves `clock` forward by `total` in small steps, yielding before each so
  /// the router's sleeps are registered.
  private static func step(_ clock: TestClock<Duration>, by total: Duration) async {
    let increment: Duration = .milliseconds(250)
    var elapsed: Duration = .zero
    while elapsed < total {
      await Task.megaYield()
      await clock.advance(by: increment)
      elapsed += increment
    }
    await Task.megaYield()
  }

  /// Steps `clock` until `condition` holds, for at most `limit`. Returns whether it held.
  private static func step(
    _ clock: TestClock<Duration>, until condition: () -> Bool, within limit: Duration
  ) async -> Bool {
    let increment: Duration = .milliseconds(250)
    var elapsed: Duration = .zero
    while elapsed < limit {
      if await RemoteRouterTestSupport.settle(condition) { return true }
      await clock.advance(by: increment)
      elapsed += increment
    }
    return await RemoteRouterTestSupport.settle(condition)
  }

  @Test func aHeldResizeFromAConnectionThatIsNotAttachedIsIgnored() async {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock)
    defer { harness.router.stop() }
    let phone = harness.openPhone("phone-1")
    harness.send("phone-1", Self.resize(harness.contents[0], hold: true))
    await Self.step(clock, by: RemoteHostRouter.resizeReadyTimeout + .seconds(1))
    #expect(phone.frames.value.isEmpty)
    #expect(harness.router.heldGrids.isEmpty)
  }

  @Test func theOwnersDetachEndsTheHoldAnotherPhonesDoesNot() {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock)
    defer { harness.router.stop() }
    let tab = harness.contents[0]
    _ = harness.openPhone("phone-1")
    _ = harness.openPhone("phone-2")
    harness.send("phone-1", Self.attach(tab, keep: true))
    harness.send("phone-2", Self.attach(tab, keep: true))
    harness.send("phone-1", Self.resize(tab, cols: 120, rows: 40, hold: true))
    #expect(harness.router.heldGrids[tab] == .init(owner: "phone-1", columns: 120, rows: 40))
    harness.send("phone-2", #"{"t":"detach","contentId":"\#(tab.uuidString)"}"#)
    #expect(harness.router.heldGrids[tab]?.owner == "phone-1")
    harness.send("phone-1", #"{"t":"detach","contentId":"\#(tab.uuidString)"}"#)
    #expect(harness.router.heldGrids.isEmpty)
    #expect(harness.router.orphanedHolds.isEmpty)
  }

  @Test func aDetachWithoutContentEndsEveryHoldOfThatPhone() {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock)
    defer { harness.router.stop() }
    let (tabA, tabB) = (harness.contents[0], harness.contents[1])
    _ = harness.openPhone("phone-1")
    harness.send("phone-1", Self.attach(tabA, keep: true))
    harness.send("phone-1", Self.attach(tabB, keep: true))
    harness.send("phone-1", Self.resize(tabA, hold: true))
    harness.send("phone-1", Self.resize(tabB, hold: true))
    #expect(harness.router.heldGrids.count == 2)
    harness.send("phone-1", #"{"t":"detach"}"#)
    #expect(harness.router.heldGrids.isEmpty)
  }

  @Test func anAttachWithoutKeepEndsTheHoldsOfTheOthersAKeptReAttachKeepsIt() {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock)
    defer { harness.router.stop() }
    let (tabA, tabB) = (harness.contents[0], harness.contents[1])
    _ = harness.openPhone("phone-1")
    harness.send("phone-1", Self.attach(tabA, keep: true))
    harness.send("phone-1", Self.resize(tabA, hold: true))
    // Re-attaching the held terminal itself is no detach of it.
    harness.send("phone-1", Self.attach(tabA, keep: true))
    #expect(harness.router.heldGrids[tabA]?.owner == "phone-1")
    harness.send("phone-1", Self.attach(tabA, keep: false))
    #expect(harness.router.heldGrids[tabA]?.owner == "phone-1")
    harness.send("phone-1", Self.attach(tabB, keep: false))
    #expect(harness.router.heldGrids.isEmpty)
  }

  @Test func aPlainResizeAfterAHeldOneEndsTheHold() {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock)
    defer { harness.router.stop() }
    let tab = harness.contents[0]
    _ = harness.openPhone("phone-1")
    _ = harness.openPhone("phone-2")
    harness.send("phone-1", Self.attach(tab, keep: true))
    harness.send("phone-2", Self.attach(tab, keep: true))
    harness.send("phone-1", Self.resize(tab, hold: true))
    // An ignored request (bad size) ends nothing.
    harness.send("phone-2", #"{"t":"resize","contentId":"\#(tab.uuidString)","cols":"wide","rows":30}"#)
    #expect(harness.router.heldGrids[tab]?.owner == "phone-1")
    harness.send("phone-2", Self.resize(tab, cols: 90, rows: 25, hold: false))
    #expect(harness.router.heldGrids.isEmpty)
  }

  @Test func aFailedHeldResizeEndsTheHold() async throws {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock)
    defer { harness.router.stop() }
    let tab = harness.contents[0]
    let phone = harness.openPhone("phone-1")
    harness.send("phone-1", Self.attach(tab, keep: true))
    harness.send("phone-1", Self.resize(tab, hold: true))
    #expect(harness.router.heldGrids[tab] != nil)
    let failed = await Self.step(
      clock, until: { !phone.messages(ofType: "error").isEmpty },
      within: RemoteHostRouter.resizeReadyTimeout + .seconds(2))
    #expect(failed)
    let error = try #require(phone.messages(ofType: "error").first)
    #expect(error["code"] as? String == RemoteResizeResult.errorCode)
    #expect(harness.router.heldGrids.isEmpty)
  }

  @Test func aClosedConnectionKeepsTheHoldForThirtySeconds() async {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock)
    defer { harness.router.stop() }
    let tab = harness.contents[0]
    _ = harness.openPhone("phone-1")
    harness.send("phone-1", Self.attach(tab, keep: true))
    harness.send("phone-1", Self.resize(tab, hold: true))
    harness.router.lanClosed("phone-1")
    #expect(harness.router.heldGrids[tab] == .init(owner: nil, columns: 100, rows: 30))
    #expect(harness.router.orphanedHolds == [tab])
    await Self.step(clock, by: RemoteGridHolds.grace - .milliseconds(500))
    #expect(harness.router.heldGrids[tab] == .init(owner: nil, columns: 100, rows: 30))
    let ended = await Self.step(clock, until: { harness.router.heldGrids.isEmpty }, within: .seconds(3))
    #expect(ended)
    #expect(harness.router.orphanedHolds.isEmpty)
  }

  @Test func aRelayConnectionCloseStartsTheGraceToo() {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock)
    defer { harness.router.stop() }
    let tab = harness.contents[0]
    _ = harness.openPhone("phone-1")
    harness.send("phone-1", Self.attach(tab, keep: true))
    harness.send("phone-1", Self.resize(tab, hold: true))
    harness.send("phone-1", #"{"t":"conn.close"}"#)
    #expect(harness.router.heldGrids[tab]?.owner == nil)
    #expect(harness.router.heldGrids[tab] != nil)
    #expect(harness.router.orphanedHolds == [tab])
  }

  @Test func aHoldTakenOverInsideTheGraceOutlivesTheTimer() async {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock)
    defer { harness.router.stop() }
    let tab = harness.contents[0]
    _ = harness.openPhone("phone-1")
    harness.send("phone-1", Self.attach(tab, keep: true))
    harness.send("phone-1", Self.resize(tab, hold: true))
    harness.router.lanClosed("phone-1")
    await Self.step(clock, by: .seconds(27))
    _ = harness.openPhone("phone-2")
    harness.send("phone-2", Self.attach(tab, keep: true))
    harness.send("phone-2", Self.resize(tab, hold: true))
    #expect(harness.router.heldGrids[tab]?.owner == "phone-2")
    #expect(harness.router.orphanedHolds.isEmpty)
    // Past the first owner's 30 s, short of phone-2's own resize_failed (6 s after its request).
    await Self.step(clock, by: .milliseconds(4_500))
    #expect(harness.router.heldGrids[tab]?.owner == "phone-2")
  }

  @Test func aClosedStreamOrphansOnlyItsContent() async throws {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock)
    defer { harness.router.stop() }
    let (tabA, tabB) = (harness.contents[0], harness.contents[1])
    _ = harness.openPhone("phone-1")
    harness.send("phone-1", Self.attach(tabA, keep: true))
    harness.send("phone-1", Self.attach(tabB, keep: true))
    harness.send("phone-1", Self.resize(tabA, hold: true))
    harness.send("phone-1", Self.resize(tabB, hold: true))
    let streamA = try #require(harness.streams(of: tabA).last)
    streamA.emit(.closed(reason: "session ended"))
    let orphaned = await RemoteRouterTestSupport.settle { harness.router.heldGrids[tabA]?.owner == nil }
    #expect(orphaned)
    #expect(harness.router.heldGrids[tabA] != nil)
    #expect(harness.router.heldGrids[tabB]?.owner == "phone-1")
    #expect(harness.router.orphanedHolds == [tabA])
  }

  @Test func stopEndsEveryHold() {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock)
    let tab = harness.contents[0]
    _ = harness.openPhone("phone-1")
    harness.send("phone-1", Self.attach(tab, keep: true))
    harness.send("phone-1", Self.resize(tab, hold: true))
    harness.router.stop()
    #expect(harness.router.heldGrids.isEmpty)
    #expect(harness.router.orphanedHolds.isEmpty)
  }
}
