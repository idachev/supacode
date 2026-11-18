import Clocks
import ConcurrencyExtras
import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

/// The layout actions `tab.close`, `pane.split` and `pane.close` (ПТ4): the
/// pure lookups and rejections, then the router on `RemoteRouterHarness`
/// (a no-op store, or `liveLayouts` where the layout really changes).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RemoteAccessLayoutActionTests {
  // MARK: - Pure

  @Test func directionAcceptsOnlyTheTwoAxes() {
    #expect(RemoteLayoutActions.direction(RemoteLenientString("horizontal")) == .horizontal)
    #expect(RemoteLayoutActions.direction(RemoteLenientString("vertical")) == .vertical)
    for bad in ["right", "h", "", "Horizontal"] {
      #expect(RemoteLayoutActions.direction(RemoteLenientString(bad)) == nil)
    }
    #expect(RemoteLayoutActions.direction(RemoteLenientString(nil)) == nil)
    #expect(RemoteLayoutActions.direction(nil) == nil)
  }

  private static func tab() -> TabItem {
    let id = UUID()
    return TabItem(
      id: TabID(rawValue: id), title: "t",
      content: ContentSnapshot(
        id: ContentID(rawValue: id), state: .terminal(TerminalContentState(workingDirectory: nil)))
    )
  }

  @Test func aTabAndAPaneAreFoundInTheLayoutThatHoldsThem() {
    let tabOfA = Self.tab()
    let paneOfA = Pane(id: PaneID(), tabs: [tabOfA])
    let layoutA = PaneLayout(tree: SplitTree(view: paneOfA.id), panes: [paneOfA], focusedPaneID: paneOfA.id)
    // "/b" is split per tab: an active group and a parked group holding `parkedTab`.
    let activePane = Pane(id: PaneID(), tabs: [Self.tab()])
    let parkedTab = Self.tab()
    let parkedPane = Pane(id: PaneID(), tabs: [parkedTab])
    let active = PaneGroupID(rawValue: UUID())
    let parked = PaneGroupID(rawValue: UUID())
    let layoutB = PaneLayout(
      tree: SplitTree(view: activePane.id), panes: [activePane, parkedPane], focusedPaneID: activePane.id,
      activeGroupID: active,
      parkedGroups: [PaneGroup(id: parked, tree: SplitTree(view: parkedPane.id), focusedPaneID: parkedPane.id)],
      groupOrder: [active, parked])
    let layouts: [(worktreeID: String, layout: PaneLayout)] = [("/a", layoutA), ("/b", layoutB)]

    #expect(RemoteLayoutActions.locate(tab: parkedTab.id.rawValue, in: layouts) == "/b")
    #expect(RemoteLayoutActions.locate(tab: tabOfA.id.rawValue, in: layouts) == "/a")
    #expect(RemoteLayoutActions.locate(pane: paneOfA.id.rawValue, in: layouts) == "/a")
    #expect(RemoteLayoutActions.locate(pane: parkedPane.id.rawValue, in: layouts) == "/b")
    #expect(RemoteLayoutActions.locate(tab: UUID(), in: layouts) == nil)
    #expect(RemoteLayoutActions.locate(pane: UUID(), in: layouts) == nil)
    // Strict ids: a tab id is not a pane, a pane id is not a tab.
    #expect(RemoteLayoutActions.locate(pane: tabOfA.id.rawValue, in: layouts) == nil)
    #expect(RemoteLayoutActions.locate(tab: paneOfA.id.rawValue, in: layouts) == nil)
  }

  @Test func rejectionsCarryTheirCodes() {
    #expect(RemoteLayoutActionRejection.missingTab.code == "tab_invalid")
    #expect(RemoteLayoutActionRejection.unknownTab.code == "tab_invalid")
    #expect(RemoteLayoutActionRejection.tabStillThere.code == "tab_failed")
    #expect(RemoteLayoutActionRejection.missingPane.code == "pane_invalid")
    #expect(RemoteLayoutActionRejection.missingSplitPane.code == "pane_invalid")
    #expect(RemoteLayoutActionRejection.unknownPane.code == "pane_invalid")
    #expect(RemoteLayoutActionRejection.badDirection.code == "pane_invalid")
    #expect(RemoteLayoutActionRejection.paneStillThere.code == "pane_failed")
    #expect(RemoteLayoutActionRejection.splitDidNotStart.code == "pane_failed")
  }

  @Test func rejectionsCarryTheProtocolTexts() {
    #expect(RemoteLayoutActionRejection.missingTab.message == "tab.close needs a tabId")
    #expect(RemoteLayoutActionRejection.unknownTab.message == "no such tab")
    #expect(RemoteLayoutActionRejection.tabStillThere.message == "the tab is still open on the Mac")
    #expect(RemoteLayoutActionRejection.missingPane.message == "pane.close needs a paneId")
    #expect(RemoteLayoutActionRejection.missingSplitPane.message == "pane.split needs a paneId")
    #expect(RemoteLayoutActionRejection.unknownPane.message == "no such pane")
    #expect(RemoteLayoutActionRejection.badDirection.message == "direction must be horizontal or vertical")
    #expect(RemoteLayoutActionRejection.paneStillThere.message == "the pane is still open on the Mac")
    #expect(RemoteLayoutActionRejection.splitDidNotStart.message == "the new pane did not start on the Mac")
  }

  private static func json(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @Test func theRepliesEncodeANullID() throws {
    let close = try Self.json(RemoteJSON.encode(RemoteTabCloseMessage(id: nil, tabId: "T", worktreeId: "/a")))
    #expect(close["id"] is NSNull)
    #expect(close["t"] as? String == "tab.close")
    #expect(close["tabId"] as? String == "T")
    #expect(close["worktreeId"] as? String == "/a")
    let paneClose = try Self.json(RemoteJSON.encode(RemotePaneCloseMessage(id: nil, paneId: "P", worktreeId: "/a")))
    #expect(paneClose["id"] is NSNull)
    #expect(paneClose["t"] as? String == "pane.close")
    #expect(paneClose["paneId"] as? String == "P")
    let split = try Self.json(
      RemoteJSON.encode(RemotePaneSplitMessage(id: nil, worktreeId: "/a", paneId: "P", tabId: "T", contentId: "T")))
    #expect(split["id"] is NSNull)
    #expect(split["t"] as? String == "pane.split")
    #expect(split["contentId"] as? String == "T")
  }

  // MARK: - Router: refusals

  private static func error(_ phone: RemoteFrameLog) throws -> [String: Any] {
    let error = try #require(phone.messages.last)
    #expect(error["t"] as? String == "error")
    return error
  }

  @Test func tabCloseOfAnUnknownTabAnswersTabInvalid() throws {
    let harness = RemoteRouterHarness(clock: TestClock())
    defer { harness.router.stop() }
    let phone = harness.openPhone("phone-1")
    harness.send("phone-1", #"{"t":"tab.close","id":6,"tabId":"\#(UUID().uuidString)"}"#)
    let error = try Self.error(phone)
    #expect(error["id"] as? Int == 6)
    #expect(error["code"] as? String == "tab_invalid")
    #expect(error["message"] as? String == "no such tab")
  }

  @Test func tabCloseWithoutATabIDAnswersTabInvalid() throws {
    let harness = RemoteRouterHarness(clock: TestClock())
    defer { harness.router.stop() }
    let phone = harness.openPhone("phone-1")
    harness.send("phone-1", #"{"t":"tab.close","id":6}"#)
    let error = try Self.error(phone)
    #expect(error["id"] as? Int == 6)
    #expect(error["code"] as? String == "tab_invalid")
    #expect(error["message"] as? String == "tab.close needs a tabId")
    harness.send("phone-1", #"{"t":"tab.close","id":7,"tabId":"not-a-uuid"}"#)
    let malformed = try Self.error(phone)
    #expect(malformed["id"] as? Int == 7)
    #expect(malformed["message"] as? String == "no such tab")
  }

  @Test func paneSplitWithABadDirectionAnswersPaneInvalid() throws {
    let harness = RemoteRouterHarness(clock: TestClock())
    defer { harness.router.stop() }
    let phone = harness.openPhone("phone-1")
    harness.send("phone-1", #"{"t":"pane.split","id":7,"paneId":"\#(UUID().uuidString)","direction":"right"}"#)
    let error = try Self.error(phone)
    #expect(error["id"] as? Int == 7)
    #expect(error["code"] as? String == "pane_invalid")
    #expect(error["message"] as? String == "direction must be horizontal or vertical")
    harness.send("phone-1", #"{"t":"pane.split","id":8,"paneId":"\#(UUID().uuidString)","direction":1}"#)
    #expect(try Self.error(phone)["message"] as? String == "direction must be horizontal or vertical")
    harness.send("phone-1", #"{"t":"pane.split","id":9,"direction":"vertical"}"#)
    #expect(try Self.error(phone)["message"] as? String == "pane.split needs a paneId")
    harness.send("phone-1", #"{"t":"pane.split","id":10,"paneId":"\#(UUID().uuidString)","direction":"vertical"}"#)
    let unknown = try Self.error(phone)
    #expect(unknown["code"] as? String == "pane_invalid")
    #expect(unknown["message"] as? String == "no such pane")
  }

  @Test func paneCloseOfAnUnknownPaneAnswersPaneInvalid() throws {
    let harness = RemoteRouterHarness(clock: TestClock())
    defer { harness.router.stop() }
    let phone = harness.openPhone("phone-1")
    harness.send("phone-1", #"{"t":"pane.close","id":8,"paneId":"\#(UUID().uuidString)"}"#)
    let error = try Self.error(phone)
    #expect(error["id"] as? Int == 8)
    #expect(error["code"] as? String == "pane_invalid")
    #expect(error["message"] as? String == "no such pane")
    harness.send("phone-1", #"{"t":"pane.close","id":9}"#)
    #expect(try Self.error(phone)["message"] as? String == "pane.close needs a paneId")
  }

  /// The no-op store never closes anything: the tab and the pane stay.
  @Test func aCloseTheMacDidNotApplyAnswersFailed() throws {
    let harness = RemoteRouterHarness(clock: TestClock())
    defer { harness.router.stop() }
    let phone = harness.openPhone("phone-1")
    let pane = try #require(harness.layout?.panes.first)
    let tab = try #require(pane.tabs.first)
    harness.send("phone-1", #"{"t":"tab.close","id":6,"tabId":"\#(tab.id.rawValue.uuidString)"}"#)
    let tabError = try Self.error(phone)
    #expect(tabError["id"] as? Int == 6)
    #expect(tabError["code"] as? String == "tab_failed")
    #expect(tabError["message"] as? String == "the tab is still open on the Mac")
    harness.send("phone-1", #"{"t":"pane.close","id":8,"paneId":"\#(pane.id.rawValue.uuidString)"}"#)
    let paneError = try Self.error(phone)
    #expect(paneError["id"] as? Int == 8)
    #expect(paneError["code"] as? String == "pane_failed")
    #expect(paneError["message"] as? String == "the pane is still open on the Mac")
  }

  // MARK: - Router: live layout

  @Test func tabCloseOfAnExistingTabClosesItAndAnswersItsWorktree() throws {
    let harness = RemoteRouterHarness(clock: TestClock(), liveLayouts: true)
    defer { harness.router.stop() }
    let phone = harness.openPhone("phone-1")
    let tab = try #require(harness.layout?.panes.first?.tabs.first)
    harness.send("phone-1", #"{"t":"tab.close","id":6,"tabId":"\#(tab.id.rawValue.uuidString)"}"#)
    let reply = try #require(phone.messages.last)
    #expect(reply["t"] as? String == "tab.close")
    #expect(reply["id"] as? Int == 6)
    #expect(reply["tabId"] as? String == tab.id.rawValue.uuidString)
    #expect(reply["worktreeId"] as? String == harness.worktreeID.rawValue)
    #expect(harness.layout?.pane(containingTab: tab.id) == nil)
    #expect(harness.layout?.panes.first?.tabs.count == 1)
  }

  @Test func paneCloseOfAnExistingPaneClosesItAndAnswersItsWorktree() throws {
    let harness = RemoteRouterHarness(clock: TestClock(), liveLayouts: true)
    defer { harness.router.stop() }
    let phone = harness.openPhone("phone-1")
    let pane = try #require(harness.layout?.panes.first)
    harness.send("phone-1", #"{"t":"pane.close","id":8,"paneId":"\#(pane.id.rawValue.uuidString)"}"#)
    let reply = try #require(phone.messages.last)
    #expect(reply["t"] as? String == "pane.close")
    #expect(reply["id"] as? Int == 8)
    #expect(reply["paneId"] as? String == pane.id.rawValue.uuidString)
    #expect(reply["worktreeId"] as? String == harness.worktreeID.rawValue)
    #expect(harness.layout?.panes[id: pane.id] == nil)
  }

  /// Steps the clock one poll interval at a time until the phone got a frame
  /// of `type` (a single long `advance` can miss a sleep registered late).
  private static func awaitFrame(
    _ type: String, on phone: RemoteFrameLog, clock: TestClock<Duration>, maxSteps: Int = 150
  ) async -> [String: Any]? {
    var steps = 0
    while phone.messages(ofType: type).isEmpty, steps < maxSteps {
      await Task.megaYield()
      await clock.advance(by: RemoteHostRouter.tabNewPollInterval)
      steps += 1
    }
    return phone.messages(ofType: type).last
  }

  @Test func paneSplitOfAnExistingPaneAnswersTheNewPaneAndItsTab() async throws {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock, liveLayouts: true)
    defer { harness.router.stop() }
    let phone = harness.openPhone("phone-1")
    let pane = try #require(harness.layout?.panes.first)
    harness.send(
      "phone-1", #"{"t":"pane.split","id":7,"paneId":"\#(pane.id.rawValue.uuidString)","direction":"horizontal"}"#)
    let reply = try #require(await Self.awaitFrame("pane.split", on: phone, clock: clock))
    #expect(reply["id"] as? Int == 7)
    #expect(reply["worktreeId"] as? String == harness.worktreeID.rawValue)
    let tabID = try #require(reply["tabId"] as? String)
    #expect(reply["contentId"] as? String == tabID)
    let newPane = try #require(reply["paneId"] as? String)
    #expect(newPane != pane.id.rawValue.uuidString)
    let layout = try #require(harness.layout)
    #expect(layout.panes.count == 2)
    let tab = try #require(UUID(uuidString: tabID))
    #expect(layout.pane(containingTab: TabID(rawValue: tab))?.id.rawValue.uuidString == newPane)
    #expect(phone.messages(ofType: "error").isEmpty)
  }

  /// Review F11: the `tab.new` wait reads the layout through the real store on
  /// every poll (`contentID(ofTab:in:)`), which must not trap on the
  /// test-built `Store`. The harness's terminal never gets a live surface to
  /// size, so the wait answers its error at the deadline.
  @Test func aNewTabWithoutALiveTerminalAnswersItsErrorAtTheDeadline() async throws {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock, liveLayouts: true)
    defer { harness.router.stop() }
    let phone = harness.openPhone("phone-1")
    harness.send("phone-1", #"{"t":"tab.new","id":9,"worktreeId":"\#(harness.worktreeID.rawValue)"}"#)
    let error = try #require(await Self.awaitFrame("error", on: phone, clock: clock))
    #expect(error["id"] as? Int == 9)
    #expect(error["message"] as? String == "the new tab did not start on the Mac")
    #expect(phone.messages(ofType: "tab.new").isEmpty)
  }

  /// The no-op store never splits: the wait gives up at the deadline.
  @Test func aSplitThatNeverLandsAnswersPaneFailed() async throws {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock)
    defer { harness.router.stop() }
    let phone = harness.openPhone("phone-1")
    let pane = try #require(harness.layout?.panes.first)
    harness.send(
      "phone-1", #"{"t":"pane.split","id":7,"paneId":"\#(pane.id.rawValue.uuidString)","direction":"vertical"}"#)
    let error = try #require(await Self.awaitFrame("error", on: phone, clock: clock))
    #expect(error["id"] as? Int == 7)
    #expect(error["code"] as? String == "pane_failed")
    #expect(error["message"] as? String == "the new pane did not start on the Mac")
    #expect(phone.messages(ofType: "pane.split").isEmpty)
  }
}
