import Foundation
import Testing

@testable import supacode

/// One remote window per Mac (Task 16): the registry every remote window joins, driven through
/// stand-in windows (a real `Store` in a test cannot be read through observation).
@MainActor
struct RemoteClientWindowsTests {
  /// One remote window: records what the registry asked of it.
  @MainActor
  final class FakeWindow: RemoteClientWindowHandle {
    private(set) var others: [Set<String>] = []
    private(set) var taps: [RemoteClientNotifier.Target] = []
    private(set) var broughtForward = 0
    private(set) var closes = 0
    private(set) var closedNow = 0
    var relayListsNoHosts = false

    nonisolated deinit {}

    func otherWindowsChanged(_ hostIDs: Set<String>) { others.append(hostIDs) }
    func notificationOpened(_ target: RemoteClientNotifier.Target) { taps.append(target) }
    func bringForward() { broughtForward += 1 }
    func close() async { closes += 1 }  // swiftlint:disable:this async_without_await
    func closeNow() { closedNow += 1 }
  }

  struct Rig {
    let registry = RemoteClientWindowRegistry()
    let opened = OpenLog()

    init() {
      registry.openWindow = { [opened] in opened.values.append($0) }
    }

    /// A window registered and showing `hostID` (nil: the picker).
    func window(_ hostID: String?) -> (UUID, FakeWindow) {
      let id = UUID()
      let window = FakeWindow()
      registry.register(id, handle: window)
      if let hostID { #expect(registry.claim(hostID, for: id)) }
      return (id, window)
    }
  }

  @MainActor
  final class OpenLog {
    var values: [RemoteClientWindowValue] = []
    nonisolated deinit {}
  }

  @Test func aMacIsClaimedByOneWindowOnly() {
    let rig = Rig()
    let (officeID, _) = rig.window("office")
    let (otherID, _) = rig.window(nil)
    #expect(!rig.registry.claim("office", for: otherID))
    // Its own Mac again ("Try Again"): still its own.
    #expect(rig.registry.claim("office", for: officeID))
    #expect(rig.registry.claim("home", for: otherID))
  }

  @Test func everyWindowLearnsTheMacsTheOthersShow() {
    let rig = Rig()
    let (_, office) = rig.window("office")
    let (homeID, home) = rig.window(nil)
    #expect(office.others.last == [])
    #expect(home.others.last == ["office"])
    #expect(rig.registry.claim("home", for: homeID))
    #expect(office.others.last == ["home"])
    // Its own claim tells it nothing new.
    #expect(home.others.last == ["office"])
    // The home window switches Macs (МХ3): the office window sees the new one only.
    #expect(rig.registry.claim("lab", for: homeID))
    #expect(office.others.last == ["lab"])
  }

  @Test func openingAMacAWindowShowsFocusesThatWindow() {
    let rig = Rig()
    let (_, office) = rig.window("office")
    #expect(rig.registry.focus("office"))
    #expect(office.broughtForward == 1)
    #expect(!rig.registry.focus("home"))
    // "Open Remote Mac…" while a window is open: a new window with the picker, whichever Mac is
    // saved (the picker leaves out the Macs already shown).
    rig.registry.openRemoteMac(saved: "office")
    #expect(rig.opened.values == [RemoteClientWindowValue(hostID: nil)])
    #expect(office.broughtForward == 1)
  }

  /// F3: an old relay lists no Macs, so a second window would show its one Mac again. The window on
  /// it comes forward instead, bound or not; once its relay lists Macs, a picker opens again.
  @Test func anOldRelaysWindowComesForwardInsteadOfASecondOne() {
    let rig = Rig()
    let (_, office) = rig.window("office")
    let (_, picker) = rig.window(nil)
    office.relayListsNoHosts = true
    rig.registry.openRemoteMac(saved: "office")
    #expect(rig.opened.values.isEmpty)
    #expect(office.broughtForward == 1)
    #expect(picker.broughtForward == 0)
    office.relayListsNoHosts = false
    rig.registry.openRemoteMac(saved: "office")
    #expect(rig.opened.values == [RemoteClientWindowValue(hostID: nil)])
  }

  /// F9: a notification tap before any view installed the opener opens its window once the opener
  /// is set, and only once though the opener is set again.
  @Test func aTapBeforeTheOpenerIsInstalledOpensWhenItIs() throws {
    let registry = RemoteClientWindowRegistry()
    let opened = OpenLog()
    let router = RemoteClientNotificationRouter(windows: registry)
    let url = try #require(RemoteClientNotifier.url(hostID: "home", worktreeID: "w1", contentID: "c1"))
    #expect(router.open(url))
    registry.openWindow = { [opened] in opened.values.append($0) }
    #expect(opened.values == [RemoteClientWindowValue(hostID: "home")])
    registry.openWindow = { [opened] in opened.values.append($0) }
    #expect(opened.values == [RemoteClientWindowValue(hostID: "home")])
  }

  /// R29: with no remote window, the saved Mac's window (the one-Mac flow); with one, a picker.
  @Test func openRemoteMacFollowsTheOneMacFlow() {
    #expect(RemoteClientWindowValue.toOpen(hasOpenWindows: false, saved: "office") == .init(hostID: "office"))
    #expect(RemoteClientWindowValue.toOpen(hasOpenWindows: false, saved: nil) == .init(hostID: nil))
    #expect(RemoteClientWindowValue.toOpen(hasOpenWindows: true, saved: "office") == .init(hostID: nil))
    let rig = Rig()
    rig.registry.openRemoteMac(saved: "office")
    #expect(rig.opened.values == [RemoteClientWindowValue(hostID: "office")])
    _ = rig.window("office")
    rig.registry.openRemoteMac(saved: "office")
    #expect(rig.opened.values == [RemoteClientWindowValue(hostID: "office"), RemoteClientWindowValue(hostID: nil)])
  }

  @Test func closingOneWindowClosesOnlyItsSessionAndFreesItsMac() async {
    let rig = Rig()
    let (officeID, office) = rig.window("office")
    let (homeID, home) = rig.window("home")
    rig.registry.windowClosed(officeID)
    #expect(home.others.last == [])
    #expect(await RemoteRouterTestSupport.settle { office.closes == 1 })
    #expect(home.closes == 0)
    #expect(rig.registry.hasOpenWindows)
    // Its Mac is free again: another window may take it.
    #expect(rig.registry.claim("office", for: homeID))
    #expect(!rig.registry.focus("home"))
  }

  @Test func quittingClosesEverySessionNow() {
    let rig = Rig()
    let (_, office) = rig.window("office")
    let (_, home) = rig.window("home")
    let (_, picker) = rig.window(nil)
    rig.registry.closeAll()
    #expect([office.closedNow, home.closedNow, picker.closedNow] == [Int](repeating: 1, count: 3))
  }

  @Test func aNotificationForHomeBringsHomesWindowForward() throws {
    let rig = Rig()
    let (_, office) = rig.window("office")
    let (_, home) = rig.window("home")
    let router = RemoteClientNotificationRouter(windows: rig.registry)
    let url = try #require(RemoteClientNotifier.url(hostID: "home", worktreeID: "w1", contentID: "c1"))
    #expect(router.open(url))
    #expect(home.broughtForward == 1)
    #expect(home.taps == [RemoteClientNotifier.Target(hostID: "home", worktreeID: "w1", contentID: "c1")])
    #expect(office.broughtForward == 0)
    #expect(office.taps.isEmpty)
    #expect(rig.opened.values.isEmpty)
  }

  @Test func aNotificationForAMacWithNoWindowOpensOne() throws {
    let rig = Rig()
    let (_, office) = rig.window("office")
    let router = RemoteClientNotificationRouter(windows: rig.registry)
    let url = try #require(RemoteClientNotifier.url(hostID: "home", worktreeID: "w1", contentID: "c1"))
    #expect(router.open(url))
    #expect(rig.opened.values == [RemoteClientWindowValue(hostID: "home")])
    #expect(office.taps.isEmpty)
  }
}
