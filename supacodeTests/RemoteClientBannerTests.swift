import Clocks
import Foundation
import Testing

@testable import supacode

struct RemoteClientBannerTests {
  typealias Banner = RemoteConnectionBanner

  private static func text(
    _ status: RemoteClientStatus, attached: Bool = false, was: Bool = false,
    host: String? = "Office Mac"
  ) -> String? {
    Banner.text(status: status, isAttached: attached, wasAttached: was, hostName: host)
  }

  // MARK: The text of each state

  @Test func aLiveTerminalHasNoBanner() {
    #expect(Self.text(.online(.lan), attached: true) == nil)
    #expect(Self.text(.online(.relay), attached: true, was: true) == nil)
  }

  @Test func anOfflineMacIsNamed() {
    #expect(Self.text(.hostOffline) == "Office Mac is offline.")
  }

  @Test func aLostConnectionSaysTypingIsNotSent() {
    #expect(Self.text(.failed("x"), host: nil) == "No connection to the Mac. Typing is not sent.")
  }

  @Test func reattachingShowsConnecting() {
    #expect(Self.text(.online(.relay), host: "A") == "Connecting to A…")
    #expect(Self.text(.online(.lan), was: true, host: "A") == "Connecting to A…")
  }

  @Test func connectingBeforeAnyAttachShowsConnecting() {
    #expect(Self.text(.connecting) == "Connecting to Office Mac…")
  }

  @Test func connectingAfterATerminalWasAttachedSaysTypingIsNotSent() {
    #expect(Self.text(.connecting, was: true) == "No connection to Office Mac. Typing is not sent.")
  }

  @Test(arguments: [
    RemoteClientStatus.failed("refused"), .idle, .choosingHost, .unsupportedHost,
  ])
  func everyOtherStateSaysTypingIsNotSent(status: RemoteClientStatus) {
    #expect(Self.text(status) == "No connection to Office Mac. Typing is not sent.")
    #expect(Self.text(status, was: true) == "No connection to Office Mac. Typing is not sent.")
    #expect(Self.text(status, host: nil) == "No connection to the Mac. Typing is not sent.")
  }

  @Test func aTerminalNeverShowsAsLiveWhileTheLinkIsDown() {
    #expect(Self.text(.hostOffline, attached: true) == "Office Mac is offline.")
    #expect(
      Self.text(.failed("x"), attached: true) == "No connection to Office Mac. Typing is not sent.")
  }

  @Test func anEmptyNameIsTheMac() {
    #expect(Self.text(.hostOffline, host: "") == "the Mac is offline.")
  }

  @Test func theKindPicksTheIcon() {
    #expect(Banner.kind(status: .online(.lan), isAttached: true, wasAttached: true) == nil)
    #expect(Banner.kind(status: .connecting, isAttached: false, wasAttached: false) == .connecting)
    #expect(Banner.kind(status: .hostOffline, isAttached: false, wasAttached: true) == .hostOffline)
    #expect(
      Banner.kind(status: .failed("x"), isAttached: false, wasAttached: false) == .noConnection)
  }

  // MARK: A tab's own state

  @Test func aDriverIsAttachedFromItsAttachedUntilTheLinkIsLost() {
    var driver = RemoteTerminalDriver()
    #expect(!driver.isAttached && !driver.wasAttached)
    _ = driver.pipeOpened()
    _ = driver.event(.attached(cols: 80, rows: 24))
    #expect(driver.isAttached && driver.wasAttached)
    driver.linkLost()
    #expect(!driver.isAttached && driver.wasAttached)
    _ = driver.event(.attached(cols: 80, rows: 24))
    #expect(driver.isAttached && driver.wasAttached)
  }

  @MainActor
  @Test func theBannerFollowsTheLinkAndGoesAtTheNextAttached() async {
    let ports = RemoteTerminalPortsRecorder()
    let content = ports.liveContent(clock: TestClock<Duration>())
    defer { content.tearDown() }
    #expect(await RemoteRouterTestSupport.settle { content.isAttached })
    content.linkChanged(status: .online(.relay), hostName: "Office Mac")
    #expect(content.bannerText == nil)
    #expect(content.toolbar?.view == nil)

    content.linkChanged(status: .connecting, hostName: "Office Mac")
    #expect(content.bannerText == "No connection to Office Mac. Typing is not sent.")
    #expect(content.toolbar?.view != nil)

    // Back online but not redrawn yet: still a banner.
    content.linkChanged(status: .online(.relay), hostName: "Office Mac")
    #expect(content.bannerText == "Connecting to Office Mac…")

    ports.continuation?.yield(.attached(cols: 80, rows: 24))
    #expect(await RemoteRouterTestSupport.settle { content.bannerText == nil })
    #expect(content.toolbar?.view == nil)
  }

  @MainActor
  @Test func aTerminalNotYetAttachedShowsConnecting() {
    let ports = RemoteTerminalPortsRecorder()
    let content = ports.content(clock: TestClock<Duration>())
    defer { content.tearDown() }
    content.linkChanged(status: .online(.lan), hostName: nil)
    #expect(content.bannerText == "Connecting to the Mac…")
  }

  // MARK: The window's line

  @Test func theWindowSaysNothingWhileOnline() {
    var state = RemoteClientFeature.State()
    state.list = RemoteClientList()
    state.status = .online(.lan)
    #expect(state.connectionNotice == nil)
  }

  @Test func theWindowSaysNothingBeforeItHasAList() {
    var state = RemoteClientFeature.State()
    state.status = .connecting
    #expect(state.connectionNotice == nil)
  }

  @Test func theWindowNamesTheMacAndAfterBeingOnlineSaysTypingIsNotSent() {
    var state = RemoteClientFeature.State()
    state.list = RemoteClientList()
    state.hostName = "Office Mac"
    state.status = .connecting
    #expect(state.connectionNotice == "Connecting to Office Mac…")
    state.hasBeenOnline = true
    #expect(state.connectionNotice == "No connection to Office Mac. Typing is not sent.")
    state.status = .hostOffline
    #expect(state.connectionNotice == "Office Mac is offline.")
  }
}
