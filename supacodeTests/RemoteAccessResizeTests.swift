import Clocks
import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

/// A client's `resize` (ЗД3): waking a terminal without a live surface
/// (`RemoteHostRouter.settleResize`), confirming the size on the session PTY
/// (`confirmResize`) and the frames the requester gets (`resizeReplies`),
/// driven by a `TestClock`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RemoteAccessResizeTests {
  private static let contentID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!
  private static let contentKey = "6F9619FF-8B86-D011-B42D-00CF4FC964FF"
  private static let request = RemoteResizeRequest(contentID: contentID, columns: 139, rows: 56)

  private static func json(_ reply: RemoteHostRouter.ResizeReply) throws -> [String: Any] {
    let data: Data =
      switch reply {
      case .size(let size): RemoteJSON.encode(size)
      case .error(let error): RemoteJSON.encode(error)
      }
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  // MARK: - (a) a hibernated terminal wakes and takes the size

  @Test func aHibernatedTerminalIsWokenAndSizedOnceItsCellMetricsExist() async {
    let clock = TestClock()
    let woken = LockIsolated(0)
    let tries = LockIsolated(0)
    let wait = Task { @MainActor in
      await RemoteHostRouter.settleResize(
        first: .noSurface, clock: clock,
        wake: {
          woken.withValue { $0 += 1 }
          return true
        },
        attempt: {
          tries.withValue { $0 += 1 }
          // The woken surface reports cell metrics on the third try.
          return tries.value >= 3 ? .applied : .notReady
        })
    }
    await Task.megaYield()
    await clock.advance(by: RemoteHostRouter.resizeRetryInterval * 2)
    #expect(await wait.value == .applied)
    #expect(woken.value == 1)
    #expect(tries.value == 3)
  }

  @Test func aWokenTerminalThatIsReadyAtOnceNeedsNoClock() async {
    let clock = TestClock()
    let result = await RemoteHostRouter.settleResize(
      first: .noSurface, clock: clock, wake: { true }, attempt: { .applied })
    #expect(result == .applied)
  }

  @Test func aLiveTerminalIsNeverWoken() async {
    let clock = TestClock()
    let woken = LockIsolated(false)
    let result = await RemoteHostRouter.settleResize(
      first: .applied, clock: clock,
      wake: {
        woken.setValue(true)
        return true
      },
      attempt: { .applied })
    #expect(result == .applied)
    #expect(!woken.value)
  }

  @Test func theSizeIsConfirmedOnceThePTYHasIt() async {
    let clock = TestClock()
    let reads = LockIsolated(0)
    let wait = Task {
      await RemoteHostRouter.confirmResize(
        grid: (columns: 139, rows: 56), attempts: RemoteHostRouter.resizeConfirmAttempts,
        interval: RemoteHostRouter.resizeSettle, clock: clock,
        readSize: {
          reads.withValue { $0 += 1 }
          // The PTY follows the grid after two reads.
          return reads.value >= 3 ? (columns: 139, rows: 56) : (columns: 122, rows: 47)
        })
    }
    await Task.megaYield()
    await clock.advance(by: RemoteHostRouter.resizeSettle * 2)
    #expect(await wait.value == .matched)
    #expect(reads.value == 3)
  }

  @Test func anAppliedResizeRepliesTheAppliedSize() throws {
    let replies = RemoteHostRouter.resizeReplies(
      for: .success(.matched), request: Self.request, contentKey: Self.contentKey, requestID: nil)
    #expect(replies == [.size(RemoteSizeMessage(contentId: Self.contentKey, cols: 139, rows: 56))])
    let json = try Self.json(replies[0])
    #expect(json["t"] as? String == "size")
    #expect(json["cols"] as? Int == 139)
    #expect(json["rows"] as? Int == 56)
  }

  // MARK: - (b) a resize that cannot be applied gets an error

  @Test func aTerminalNoWorktreeListsAnyMoreFailsAtOnce() async {
    let clock = TestClock()
    let result = await RemoteHostRouter.settleResize(
      first: .noSurface, clock: clock, wake: { false }, attempt: { .noSurface })
    #expect(result == .failed(.contentGone))
  }

  @Test func aWakeThatFailsToStartTheSessionFails() async {
    let clock = TestClock()
    let result = await RemoteHostRouter.settleResize(
      first: .failedToStart, clock: clock, wake: { true }, attempt: { .failedToStart })
    #expect(result == .failed(.wakeFailed))
  }

  @Test func cellMetricsThatNeverArriveFailAtTheDeadline() async {
    let clock = TestClock()
    let wait = Task { @MainActor in
      await RemoteHostRouter.settleResize(
        first: .noSurface, clock: clock, wake: { true }, attempt: { .notReady })
    }
    await Task.megaYield()
    await clock.advance(by: RemoteHostRouter.resizeReadyTimeout)
    #expect(await wait.value == .failed(.notReady))
  }

  @Test func aFailedResizeRepliesAResizeFailedError() throws {
    let replies = RemoteHostRouter.resizeReplies(
      for: .failure(.notReady), request: Self.request, contentKey: Self.contentKey, requestID: nil)
    #expect(replies.count == 1)
    let json = try Self.json(replies[0])
    #expect(json["t"] as? String == "error")
    #expect(json.keys.contains("id"))
    #expect(json["id"] is NSNull)
    #expect(json["message"] as? String == "the terminal was not ready on the Mac in time")
    #expect(json["code"] as? String == "resize_failed")
    #expect(json["contentId"] as? String == Self.contentKey)
  }

  @Test func aFailedResizeEchoesTheRequestID() throws {
    let replies = RemoteHostRouter.resizeReplies(
      for: .failure(.contentGone), request: Self.request, contentKey: Self.contentKey, requestID: 7)
    #expect(try Self.json(replies[0])["id"] as? Int == 7)
  }

  @Test func aPTYThatKeepsItsSizeRepliesTheRealSizeThenAnError() async throws {
    let clock = TestClock()
    let wait = Task {
      await RemoteHostRouter.confirmResize(
        grid: (columns: 139, rows: 56), attempts: 3, interval: RemoteHostRouter.resizeSettle, clock: clock,
        readSize: { (columns: 122, rows: 47) })
    }
    await Task.megaYield()
    await clock.advance(by: RemoteHostRouter.resizeSettle * 2)
    let confirmation = await wait.value
    #expect(confirmation == .mismatch(columns: 122, rows: 47))
    let replies = RemoteHostRouter.resizeReplies(
      for: .success(confirmation), request: Self.request, contentKey: Self.contentKey, requestID: nil)
    #expect(replies.count == 2)
    #expect(replies.first == .size(RemoteSizeMessage(contentId: Self.contentKey, cols: 122, rows: 47)))
    #expect(try Self.json(replies[1])["code"] as? String == "resize_failed")
  }

  @Test func aPTYSizeThatCannotBeReadIsAnError() async throws {
    let clock = TestClock()
    let confirmation = await RemoteHostRouter.confirmResize(
      grid: (columns: 139, rows: 56), attempts: 1, interval: RemoteHostRouter.resizeSettle, clock: clock,
      readSize: { nil })
    #expect(confirmation == .unreadable)
    let replies = RemoteHostRouter.resizeReplies(
      for: .success(confirmation), request: Self.request, contentKey: Self.contentKey, requestID: nil)
    #expect(try Self.json(replies[0])["message"] as? String == "could not read the terminal session's size")
  }

  // MARK: - (c) a resize to the current size gets `size` at once

  @Test func aResizeToTheCurrentSizeRepliesSizeWithoutWaiting() async {
    let clock = TestClock()
    let settled = await RemoteHostRouter.settleResize(
      first: .unchanged, clock: clock, wake: { true }, attempt: { .unchanged })
    #expect(settled == .unchanged)
    // One read, no clock: the reply needs no `advance`.
    let confirmation = await RemoteHostRouter.confirmResize(
      grid: (columns: 139, rows: 56), attempts: 1, interval: RemoteHostRouter.resizeSettle, clock: clock,
      readSize: { (columns: 139, rows: 56) })
    #expect(confirmation == .matched)
    let replies = RemoteHostRouter.resizeReplies(
      for: .success(confirmation), request: Self.request, contentKey: Self.contentKey, requestID: nil)
    #expect(replies == [.size(RemoteSizeMessage(contentId: Self.contentKey, cols: 139, rows: 56))])
  }

  // MARK: - PTY size

  @Test func aProcessWithoutATerminalHasNone() {
    // launchd (pid 1) runs as root without a controlling terminal; reading it
    // must not fail on permissions the way `proc_pidinfo` did.
    #expect(ZmxRemoteStream.controllingTerminal(pid: 1) == nil)
    #expect(ZmxRemoteStream.controllingTerminal(pid: Int32.max) == nil)
  }
}
