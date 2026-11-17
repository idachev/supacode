import Clocks
import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

/// `attach` with `keep`, the limit of 16 per connection and `detach` of one
/// content (ПТ1): the policy, then the router with fake zmx streams
/// (`RemoteRouterHarness`).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RemoteAccessAttachTests {
  // MARK: - Policy

  @Test func withoutKeepEveryOtherAttachmentStops() {
    let old = UUID()
    let other = UUID()
    let new = UUID()
    #expect(
      RemoteAttachPolicy.decide(attached: [old, other], contentID: new, keep: false)
        == .attach(detaching: [old, other]))
  }

  @Test func withKeepTheOthersStay() {
    let old = UUID()
    let new = UUID()
    #expect(RemoteAttachPolicy.decide(attached: [old], contentID: new, keep: true) == .attach(detaching: []))
  }

  @Test func reAttachRestartsOnlyThatStream() {
    let same = UUID()
    let other = UUID()
    #expect(
      RemoteAttachPolicy.decide(attached: [same, other], contentID: same, keep: true)
        == .attach(detaching: [same]))
    #expect(
      RemoteAttachPolicy.decide(attached: [same, other], contentID: same, keep: false)
        == .attach(detaching: [same, other]))
  }

  @Test func theSeventeenthKeptAttachmentIsRefused() throws {
    let attached = Set((0..<16).map { _ in UUID() })
    #expect(RemoteAttachPolicy.limit == 16)
    #expect(RemoteAttachPolicy.decide(attached: attached, contentID: UUID(), keep: true) == .limitReached)
    // A re-attach at the limit is still allowed.
    let first = try #require(attached.first)
    #expect(
      RemoteAttachPolicy.decide(attached: attached, contentID: first, keep: true)
        == .attach(detaching: [first]))
    // Without keep the limit never applies: every other attachment goes.
    #expect(
      RemoteAttachPolicy.decide(attached: attached, contentID: UUID(), keep: false)
        == .attach(detaching: attached))
  }

  // MARK: - Router

  private static func attach(_ contentID: UUID, id: Int, keep: Bool?) -> String {
    let keepField = keep.map { #","keep":\#($0)"# } ?? ""
    return #"{"t":"attach","id":\#(id),"contentId":"\#(contentID.uuidString)"\#(keepField)}"#
  }

  private static func contentIDs(_ messages: [[String: Any]]) -> [String] {
    messages.compactMap { $0["contentId"] as? String }
  }

  @Test func anUnknownContentIsRefusedAndTheConnectionStaysKnown() throws {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock)
    defer { harness.router.stop() }
    let phone = harness.openPhone("phone-1")
    harness.send("phone-1", Self.attach(UUID(), id: 2, keep: true))
    let error = try #require(phone.messages.first)
    #expect(error["t"] as? String == "error")
    #expect(error["id"] as? Int == 2)
    #expect(error["message"] as? String == "no such terminal")
    #expect(harness.streams.value.isEmpty)
    harness.send("phone-1", #"{"t":"list","id":3}"#)
    let list = try #require(phone.messages.last)
    #expect(list["t"] as? String == "list")
    #expect(list["id"] as? Int == 3)
  }

  @Test func twoKeptAttachmentsBothStream() async throws {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock)
    defer { harness.router.stop() }
    let phone = harness.openPhone("phone-1")
    let (tabA, tabB) = (harness.contents[0], harness.contents[1])
    harness.send("phone-1", Self.attach(tabA, id: 1, keep: true))
    harness.send("phone-1", Self.attach(tabB, id: 2, keep: true))
    await RemoteRouterTestSupport.settle { phone.messages(ofType: "attached").count == 2 }
    let attached = phone.messages(ofType: "attached")
    #expect(Set(Self.contentIDs(attached)) == [tabA.uuidString, tabB.uuidString])
    #expect(Set(attached.compactMap { $0["id"] as? Int }) == [1, 2])
    #expect(attached.allSatisfy { $0["cols"] as? Int == 100 && $0["rows"] as? Int == 30 })
    for content in [tabA, tabB] {
      let stream = try #require(harness.streams(of: content).first)
      #expect(harness.streams(of: content).count == 1)
      #expect(stream.isStarted)
      #expect(!stream.stopped.value)
    }
    #expect(phone.messages(ofType: "detached").isEmpty)
  }

  @Test func detachingOneContentLeavesTheOtherStreamAndItsResizeWait() async throws {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock)
    defer { harness.router.stop() }
    let phone = harness.openPhone("phone-1")
    let (tabA, tabB) = (harness.contents[0], harness.contents[1])
    harness.send("phone-1", Self.attach(tabA, id: 1, keep: true))
    harness.send("phone-1", Self.attach(tabB, id: 2, keep: true))
    await RemoteRouterTestSupport.settle { phone.messages(ofType: "attached").count == 2 }
    // B has no live surface here, so its resize waits on the clock for the woken one.
    harness.send("phone-1", #"{"t":"resize","id":5,"contentId":"\#(tabB.uuidString)","cols":90,"rows":20}"#)
    await Task.megaYield()
    harness.send("phone-1", #"{"t":"detach","contentId":"\#(tabA.uuidString)"}"#)
    let streamA = try #require(harness.streams(of: tabA).first)
    let streamB = try #require(harness.streams(of: tabB).first)
    #expect(streamA.stopped.value)
    #expect(!streamB.stopped.value)
    // B's wait goes on: it ends at its own timeout and answers for B only.
    await Task.megaYield()
    await clock.advance(by: RemoteHostRouter.resizeReadyTimeout)
    await RemoteRouterTestSupport.settle { !phone.messages(ofType: "error").isEmpty }
    let errors = phone.messages(ofType: "error")
    #expect(errors.count == 1)
    #expect(errors.first?["id"] as? Int == 5)
    #expect(errors.first?["code"] as? String == "resize_failed")
    #expect(errors.first?["contentId"] as? String == tabB.uuidString)
    #expect(!streamB.stopped.value)
    #expect(phone.messages(ofType: "detached").isEmpty)
  }

  @Test func aDetachWithoutContentStopsEveryAttachment() async throws {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock)
    defer { harness.router.stop() }
    let phone = harness.openPhone("phone-1")
    harness.send("phone-1", Self.attach(harness.contents[0], id: 1, keep: true))
    harness.send("phone-1", Self.attach(harness.contents[1], id: 2, keep: true))
    await RemoteRouterTestSupport.settle { phone.messages(ofType: "attached").count == 2 }
    harness.send("phone-1", #"{"t":"detach"}"#)
    #expect(harness.streams.value.count == 2)
    #expect(harness.streams.value.allSatisfy { $0.stopped.value })
  }

  @Test func anAttachWithoutKeepStopsBothKeptAttachments() async throws {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock, tabs: 3)
    defer { harness.router.stop() }
    let phone = harness.openPhone("phone-1")
    let (tabA, tabB, tabC) = (harness.contents[0], harness.contents[1], harness.contents[2])
    harness.send("phone-1", Self.attach(tabA, id: 1, keep: true))
    harness.send("phone-1", Self.attach(tabB, id: 2, keep: true))
    await RemoteRouterTestSupport.settle { phone.messages(ofType: "attached").count == 2 }
    harness.send("phone-1", Self.attach(tabC, id: 3, keep: nil))
    await RemoteRouterTestSupport.settle { phone.messages(ofType: "attached").count == 3 }
    #expect(phone.messages(ofType: "attached").last?["contentId"] as? String == tabC.uuidString)
    #expect(try #require(harness.streams(of: tabA).first).stopped.value)
    #expect(try #require(harness.streams(of: tabB).first).stopped.value)
    let streamC = try #require(harness.streams(of: tabC).first)
    #expect(streamC.isStarted)
    #expect(!streamC.stopped.value)
  }

  @Test func theSeventeenthKeptAttachIsRefusedWithItsIDAndContent() async throws {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock, tabs: 17)
    defer { harness.router.stop() }
    let phone = harness.openPhone("phone-1")
    for (index, content) in harness.contents.prefix(16).enumerated() {
      harness.send("phone-1", Self.attach(content, id: index + 1, keep: true))
    }
    await RemoteRouterTestSupport.settle { phone.messages(ofType: "attached").count == 16 }
    #expect(phone.messages(ofType: "attached").count == 16)
    let extra = try #require(harness.contents.last)
    harness.send("phone-1", Self.attach(extra, id: 99, keep: true))
    let error = try #require(phone.messages.last)
    #expect(error["t"] as? String == "error")
    #expect(error["id"] as? Int == 99)
    #expect(error["code"] as? String == "attach_limit")
    #expect(error["message"] as? String == "too many attached terminals")
    #expect(error["contentId"] as? String == extra.uuidString)
    // Nothing changed: no stream for the refused one, every kept one still runs.
    await Task.megaYield()
    #expect(harness.streams.value.count == 16)
    #expect(harness.streams(of: extra).isEmpty)
    #expect(harness.streams.value.allSatisfy { !$0.stopped.value })
    #expect(phone.messages(ofType: "attached").count == 16)
  }

  @Test func theCloseOfAReplacedStreamSendsNoDetached() async throws {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock, tabs: 1)
    defer { harness.router.stop() }
    let phone = harness.openPhone("phone-1")
    let tab = harness.contents[0]
    harness.send("phone-1", Self.attach(tab, id: 1, keep: true))
    await RemoteRouterTestSupport.settle { phone.messages(ofType: "attached").count == 1 }
    let old = try #require(harness.streams(of: tab).first)
    old.emit(.closed(reason: "session closed"))
    // Hold the main actor until the pump took the close, so its `streamClosed`
    // runs only after the re-attach below replaced that stream.
    let deadline = Date.now.addingTimeInterval(5)
    while !old.closedTaken.value, Date.now < deadline {}
    try #require(old.closedTaken.value)
    harness.send("phone-1", Self.attach(tab, id: 2, keep: true))
    await RemoteRouterTestSupport.settle { phone.messages(ofType: "attached").count == 2 }
    for _ in 0..<5 { await Task.megaYield() }
    #expect(phone.messages(ofType: "detached").isEmpty)
    let current = try #require(harness.streams(of: tab).last)
    #expect(harness.streams(of: tab).count == 2)
    #expect(old.stopped.value)
    #expect(harness.overlappingStarts.value == 0)
    #expect(current.isStarted)
    #expect(!current.stopped.value)
    // The new attachment is still known: its input reaches its stream.
    harness.send("phone-1", #"{"t":"input","contentId":"\#(tab.uuidString)","b64":"YQ=="}"#)
    #expect(current.sent.value == [[0x61]])
    #expect(phone.messages(ofType: "error").isEmpty)
  }

  @Test func aReAttachStopsTheOldStreamBeforeTheNewOne() async throws {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock, tabs: 1)
    defer { harness.router.stop() }
    let phone = harness.openPhone("phone-1")
    let tab = harness.contents[0]
    harness.send("phone-1", Self.attach(tab, id: 1, keep: nil))
    await RemoteRouterTestSupport.settle { phone.messages(ofType: "attached").count == 1 }
    harness.send("phone-1", Self.attach(tab, id: 2, keep: nil))
    let streams = harness.streams(of: tab)
    #expect(streams.count == 2)
    #expect(harness.overlappingStarts.value == 0)
    #expect(streams.first?.stopped.value == true)
    #expect(streams.last?.stopped.value == false)
    await RemoteRouterTestSupport.settle { phone.messages(ofType: "attached").count == 2 }
    #expect(phone.messages(ofType: "attached").map { $0["id"] as? Int } == [1, 2])
    #expect(streams.last?.isStarted == true)
    #expect(phone.messages(ofType: "detached").isEmpty)
  }
}
