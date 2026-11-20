import AppKit
import Carbon.HIToolbox
import Foundation
import GhosttyKit
import SupacodeSettingsShared
import Testing

@testable import supacode

private final class HotkeyRecorderNSView: NSView {
  nonisolated deinit {}
}

@MainActor
struct GhosttySurfaceViewTests {
  @Test func normalizedWorkingDirectoryPathRemovesTrailingSlashForNonRootPath() {
    #expect(
      GhosttySurfaceView.normalizedWorkingDirectoryPath("/Users/onevcat/Sync/github/supacode/")
        == "/Users/onevcat/Sync/github/supacode"
    )
    #expect(
      GhosttySurfaceView.normalizedWorkingDirectoryPath("/Users/onevcat/Sync/github/supacode///")
        == "/Users/onevcat/Sync/github/supacode"
    )
  }

  @Test func surfaceBackingSizeOffWindowIsTheFrameNotTheMainScreenScale() {
    // A never-mounted surface's frame is already in pixels; AppKit's
    // off-window `convertToBacking` would scale it by the main screen (2x on Retina).
    let view = HotkeyRecorderNSView(frame: NSRect(x: 0, y: 0, width: 1120, height: 912))
    #expect(view.window == nil)
    #expect(
      GhosttySurfaceView.surfaceBackingSize(of: view, size: view.bounds.size)
        == CGSize(width: 1120, height: 912)
    )
  }

  // Drives the real `updateSurfaceSize` path: a never-mounted surface hands
  // Ghostty its pixel frame as is, and an exact remote grid lands exactly,
  // not at the main screen's 2x. Needs a live core surface, absent when the
  // display sleeps; then there is nothing to measure.
  @Test func unmountedSurfacePushesItsPixelFrameUnscaled() {
    let surfaceView = GhosttySurfaceView(
      id: UUID(),
      runtime: GhosttyRuntime(),
      workingDirectory: nil,
      initialGeometry: .fallback,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
    defer { surfaceView.closeSurface() }
    guard let surface = surfaceView.surface else {
      Self.recordSkippedLiveChecks()
      return
    }
    #expect(surfaceView.window == nil)

    let start = ghostty_surface_size(surface)
    #expect(CGFloat(start.width_px) == ContentGeometry.fallback.pixelSize.width)
    #expect(CGFloat(start.height_px) == ContentGeometry.fallback.pixelSize.height)
    guard Self.measuredSurface(of: surfaceView) != nil else { return }

    #expect(surfaceView.applyRequestedGrid(columns: 40, rows: 12) == .applied)
    let resized = ghostty_surface_size(surface)
    #expect(Int(resized.columns) == 40)
    #expect(Int(resized.rows) == 12)
  }

  // A never-shown surface takes a pinned grid as its start size, and a second
  // pin with another grid replaces it. Needs a live core surface with cell
  // metrics, absent when the display sleeps; then only the record is checked.
  @Test func pinGridOnANeverShownSurfaceSizesItAndRepins() {
    let surfaceView = Self.makeSurfaceView()
    defer { surfaceView.closeSurface() }
    let outcome = surfaceView.pinGrid(columns: 40, rows: 12)
    #expect(surfaceView.pinnedGrid?.columns == 40)
    #expect(surfaceView.pinnedGrid?.rows == 12)
    guard let surface = Self.measuredSurface(of: surfaceView) else { return }
    #expect(outcome == .applied)
    #expect(Self.grid(of: surface) == [40, 12])

    #expect(surfaceView.pinGrid(columns: 50, rows: 20) == .applied)
    #expect(Self.grid(of: surface) == [50, 20])
    #expect(surfaceView.pinGrid(columns: 50, rows: 20) == .unchanged)

    surfaceView.unpinGrid()
    #expect(surfaceView.pinnedGrid == nil)
  }

  // A shown surface keeps a pinned grid through layout passes that measure
  // another pane size and through a move to another window; unpinning puts
  // the pane's newest size back.
  @Test func aPinnedGridSurvivesLayoutAndAWindowMove() {
    let surfaceView = Self.makeSurfaceView()
    defer { surfaceView.closeSurface() }
    let first = Self.makeWindow()
    let second = Self.makeWindow()
    defer {
      first.close()
      second.close()
    }
    surfaceView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    first.contentView?.addSubview(surfaceView)
    guard let surface = Self.measuredSurface(of: surfaceView) else { return }
    surfaceView.updateSurfaceSize()
    let paneGrid = Self.grid(of: surface)

    #expect(surfaceView.pinGrid(columns: 40, rows: 12) == .applied)
    #expect(Self.grid(of: surface) == [40, 12])
    surfaceView.updateSurfaceSize(contentSize: CGSize(width: 600, height: 500))
    surfaceView.updateSurfaceSize(contentSize: CGSize(width: 400, height: 300))
    #expect(Self.grid(of: surface) == [40, 12])

    surfaceView.removeFromSuperview()
    second.contentView?.addSubview(surfaceView)
    surfaceView.updateSurfaceSize()
    #expect(Self.grid(of: surface) == [40, 12])

    surfaceView.unpinGrid()
    #expect(Self.grid(of: surface) == paneGrid)
  }

  // The wake order: a surface pinned while never shown keeps the grid once it
  // joins a window, through layout passes at another pane size.
  @Test func aGridPinnedBeforeTheFirstMountSurvivesTheMount() {
    let surfaceView = Self.makeSurfaceView()
    defer { surfaceView.closeSurface() }
    let window = Self.makeWindow()
    defer { window.close() }
    guard let surface = Self.measuredSurface(of: surfaceView) else { return }
    #expect(surfaceView.pinGrid(columns: 40, rows: 12) == .applied)

    surfaceView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    window.contentView?.addSubview(surfaceView)
    surfaceView.updateSurfaceSize()
    surfaceView.updateSurfaceSize(contentSize: CGSize(width: 600, height: 500))
    #expect(Self.grid(of: surface) == [40, 12])

    surfaceView.unpinGrid()
    surfaceView.updateSurfaceSize()
    #expect(Self.grid(of: surface) != [40, 12])
  }

  // Unpinning a surface that is not pinned leaves an ordinary hold alone: no
  // push of the pane size, so the requested grid stays.
  @Test func unpinningWithoutAPinKeepsAnOrdinaryHold() {
    let surfaceView = Self.makeSurfaceView()
    defer { surfaceView.closeSurface() }
    let window = Self.makeWindow()
    defer { window.close() }
    surfaceView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    window.contentView?.addSubview(surfaceView)
    guard let surface = Self.measuredSurface(of: surfaceView) else { return }
    surfaceView.updateSurfaceSize()
    #expect(surfaceView.applyRequestedGrid(columns: 40, rows: 12) == .applied)

    surfaceView.unpinGrid()
    #expect(Self.grid(of: surface) == [40, 12])
    #expect(surfaceView.applyRequestedGrid(columns: 40, rows: 12) == .unchanged)
  }

  // A font size change keeps a pinned grid's columns × rows.
  @Test func aPinnedGridSurvivesAFontSizeChange() {
    let surfaceView = Self.makeSurfaceView()
    defer { surfaceView.closeSurface() }
    let window = Self.makeWindow()
    defer { window.close() }
    surfaceView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    window.contentView?.addSubview(surfaceView)
    guard let surface = Self.measuredSurface(of: surfaceView) else { return }
    surfaceView.updateSurfaceSize()
    #expect(surfaceView.pinGrid(columns: 40, rows: 12) == .applied)
    let cellBefore = ghostty_surface_size(surface).cell_width_px

    surfaceView.performBindingAction("increase_font_size:4")
    #expect(ghostty_surface_size(surface).cell_width_px != cellBefore)
    #expect(Self.grid(of: surface) == [40, 12])
  }

  // Review F5: a degenerate pane size measured while pinned is not pushed when
  // the pin ends; the next layout pass at a usable size applies the pane's grid.
  @Test func unpinningOverADegeneratePaneSizeKeepsAUsableGrid() {
    let surfaceView = Self.makeSurfaceView()
    defer { surfaceView.closeSurface() }
    let window = Self.makeWindow()
    defer { window.close() }
    surfaceView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    window.contentView?.addSubview(surfaceView)
    guard let surface = Self.measuredSurface(of: surfaceView) else { return }
    surfaceView.updateSurfaceSize()
    let paneGrid = Self.grid(of: surface)
    #expect(surfaceView.pinGrid(columns: 40, rows: 12) == .applied)
    surfaceView.updateSurfaceSize(contentSize: CGSize(width: 4, height: 4))

    surfaceView.unpinGrid()
    #expect(Self.grid(of: surface) == [40, 12])
    surfaceView.updateSurfaceSize()
    #expect(Self.grid(of: surface) == paneGrid)
  }

  // A remote tab asks its host for the grid that fits the pane (ТР8): every
  // layout pass reports it while the pin holds the remote grid. It is the grid
  // Ghostty gives that pane unpinned, or one cell short: the padding remainder
  // the estimate keeps holds a part cell (`GridCap.fitting`).
  @Test func aPinnedSurfaceReportsThePanesFittingGrid() throws {
    let surfaceView = Self.makeSurfaceView()
    defer { surfaceView.closeSurface() }
    let window = Self.makeWindow()
    defer { window.close() }
    surfaceView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    window.contentView?.addSubview(surfaceView)
    let surface = try #require(Self.measuredSurface(of: surfaceView))
    surfaceView.updateSurfaceSize()
    var reported: [[Int]] = []
    surfaceView.onPaneGridMeasured = { columns, rows in reported.append([columns, rows]) }

    for size in [CGSize(width: 600, height: 500), CGSize(width: 523, height: 377), CGSize(width: 400, height: 300)] {
      _ = surfaceView.pinGrid(columns: 40, rows: 12)
      reported = []
      surfaceView.updateSurfaceSize(contentSize: size)
      #expect(Self.grid(of: surface) == [40, 12])
      surfaceView.unpinGrid()
      surfaceView.updateSurfaceSize(contentSize: size)
      let pane = Self.grid(of: surface)
      guard let fitting = reported.first else {
        Issue.record("no fitting grid reported at \(size)")
        continue
      }
      #expect((pane[0] - 1...pane[0]).contains(fitting[0]))
      #expect((pane[1] - 1...pane[1]).contains(fitting[1]))
    }
  }

  // Unpinned, the report follows the push, so it is the grid Ghostty itself
  // gave the pane (a remote tab before its first `attached`).
  @Test func anUnpinnedSurfaceReportsGhosttysOwnGrid() throws {
    let surfaceView = Self.makeSurfaceView()
    defer { surfaceView.closeSurface() }
    let window = Self.makeWindow()
    defer { window.close() }
    surfaceView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    window.contentView?.addSubview(surfaceView)
    let surface = try #require(Self.measuredSurface(of: surfaceView))
    surfaceView.updateSurfaceSize()
    var reported: [[Int]] = []
    surfaceView.onPaneGridMeasured = { columns, rows in reported.append([columns, rows]) }

    for size in [CGSize(width: 600, height: 500), CGSize(width: 523, height: 377), CGSize(width: 400, height: 300)] {
      reported = []
      surfaceView.updateSurfaceSize(contentSize: size)
      #expect(reported == [Self.grid(of: surface)])
    }
  }

  // Off-window and degenerate measurements are never reported: a remote host
  // would otherwise be asked for the remote grid itself or for a tiny one.
  @Test func noFittingGridOffWindowOrForADegeneratePane() throws {
    let surfaceView = Self.makeSurfaceView()
    defer { surfaceView.closeSurface() }
    var reported: [[Int]] = []
    surfaceView.onPaneGridMeasured = { columns, rows in reported.append([columns, rows]) }
    surfaceView.updateSurfaceSize()
    #expect(reported.isEmpty)

    let window = Self.makeWindow()
    defer { window.close() }
    surfaceView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    window.contentView?.addSubview(surfaceView)
    _ = try #require(Self.measuredSurface(of: surfaceView))
    surfaceView.updateSurfaceSize()
    #expect(!reported.isEmpty)
    reported = []
    surfaceView.updateSurfaceSize(contentSize: CGSize(width: 4, height: 4))
    #expect(reported.isEmpty)
  }

  @Test func theFittingGridKeepsTheSurfacesPaddingRemainder() {
    var size = ghostty_surface_size_s()
    size.columns = 40
    size.rows = 12
    size.width_px = 40 * 10 + 30
    size.height_px = 12 * 20 + 25
    size.cell_width_px = 10
    size.cell_height_px = 20
    let fitting = GhosttySurfaceView.GridCap.fitting(pane: CGSize(width: 1030.5, height: 625), surface: size)
    #expect(fitting?.columns == 100)
    #expect(fitting?.rows == 30)
    #expect(GhosttySurfaceView.GridCap.fitting(pane: CGSize(width: 70, height: 60), surface: size) == nil)
    size.cell_width_px = 0
    #expect(GhosttySurfaceView.GridCap.fitting(pane: CGSize(width: 1030, height: 625), surface: size) == nil)
  }

  // A hibernate + wake installs a new surface; the content pins it with the
  // grid it recorded, including a pin made while there was no surface.
  @Test func terminalContentPinsEverySurfaceItInstalls() throws {
    var made: [GhosttySurfaceView] = []
    let content = TerminalContent(
      id: ContentID(),
      makeSurface: { geometry, _, _ in
        let view = Self.makeSurfaceView(geometry: geometry)
        made.append(view)
        return TerminalContent.SpawnedSurface(view: view, usesZmx: true)
      },
      initialState: TerminalContentState(workingDirectory: nil)
    )
    defer { content.tearDown() }

    #expect(content.pinGrid(columns: 40, rows: 12) == nil)
    #expect(content.pinnedGrid?.columns == 40)
    #expect(content.pinnedGrid?.rows == 12)

    content.startSession(at: .fallback)
    let firstView = try #require(made.first)
    #expect(firstView.pinnedGrid?.columns == 40)
    #expect(firstView.pinnedGrid?.rows == 12)

    content.hibernate()
    content.startSession(at: .fallback)
    #expect(made.count == 2)
    let woken = try #require(made.last)
    #expect(woken !== firstView)
    #expect(woken.pinnedGrid?.columns == 40)
    #expect(woken.pinnedGrid?.rows == 12)
    if let surface = Self.measuredSurface(of: woken) {
      #expect(Self.grid(of: surface) == [40, 12])
    }

    content.unpinGrid()
    #expect(content.pinnedGrid == nil)
    #expect(woken.pinnedGrid == nil)
  }

  private static func makeSurfaceView(geometry: ContentGeometry = .fallback) -> GhosttySurfaceView {
    GhosttySurfaceView(
      id: UUID(),
      runtime: GhosttyRuntime(),
      workingDirectory: nil,
      initialGeometry: geometry,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
  }

  private static func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.borderless],
      backing: .buffered,
      defer: true
    )
    window.isReleasedWhenClosed = false
    return window
  }

  /// The view's core surface when it has cell metrics. Without them (no live
  /// core surface, e.g. while the display sleeps) the live grid checks cannot
  /// run: this records a known issue, so the run reports the skip instead of
  /// passing silently, and returns nil.
  private static func measuredSurface(of view: GhosttySurfaceView) -> ghostty_surface_t? {
    if let surface = view.surface, hasCellMetrics(surface) { return surface }
    recordSkippedLiveChecks()
    return nil
  }

  private static func recordSkippedLiveChecks() {
    withKnownIssue("No Ghostty surface with cell metrics here: the live grid checks were skipped") {
      Issue.record("the surface has no cell metrics")
    }
  }

  private static func hasCellMetrics(_ surface: ghostty_surface_t) -> Bool {
    let size = ghostty_surface_size(surface)
    return size.cell_width_px > 0 && size.cell_height_px > 0
  }

  private static func grid(of surface: ghostty_surface_t) -> [Int] {
    let size = ghostty_surface_size(surface)
    return [Int(size.columns), Int(size.rows)]
  }

  @Test func surfaceBackingSizeInWindowConvertsAtTheWindowScale() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.borderless],
      backing: .buffered,
      defer: true
    )
    window.isReleasedWhenClosed = false
    let view = HotkeyRecorderNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    window.contentView?.addSubview(view)
    let size = CGSize(width: 200, height: 100)
    #expect(GhosttySurfaceView.surfaceBackingSize(of: view, size: size) == view.convertToBacking(size))
    let scale = window.backingScaleFactor
    #expect(
      GhosttySurfaceView.surfaceBackingSize(of: view, size: size)
        == CGSize(width: 200 * scale, height: 100 * scale)
    )
  }

  @Test func normalizedWorkingDirectoryPathKeepsRootPath() {
    #expect(GhosttySurfaceView.normalizedWorkingDirectoryPath("/") == "/")
  }

  @Test func accessibilityLineCountsLineBreaksUpToIndex() {
    let content = "alpha\nbeta\ngamma"

    #expect(GhosttySurfaceView.accessibilityLine(for: 0, in: content) == 0)
    #expect(GhosttySurfaceView.accessibilityLine(for: 5, in: content) == 0)
    #expect(GhosttySurfaceView.accessibilityLine(for: 6, in: content) == 1)
    #expect(GhosttySurfaceView.accessibilityLine(for: content.count, in: content) == 2)
  }

  @Test func accessibilityStringReturnsSubstringForValidRange() {
    let content = "alpha\nbeta"

    #expect(
      GhosttySurfaceView.accessibilityString(
        for: NSRange(location: 6, length: 4),
        in: content
      ) == "beta"
    )
    #expect(
      GhosttySurfaceView.accessibilityString(
        for: NSRange(location: 99, length: 1),
        in: content
      ) == nil
    )
  }

  @Test func shouldHealOcclusionOnlyFiresForLatchedSurfaceAtKeyWindow() {
    // Not latched (nil or visible): never heal.
    #expect(
      !GhosttySurfaceView.shouldHealOcclusion(
        lastOcclusion: nil, windowIsKey: true, windowIsVisible: true, requiresVisibleWindow: false
      ))
    #expect(
      !GhosttySurfaceView.shouldHealOcclusion(
        lastOcclusion: true, windowIsKey: true, windowIsVisible: true, requiresVisibleWindow: false
      ))
    // Latched but window not key: never heal.
    #expect(
      !GhosttySurfaceView.shouldHealOcclusion(
        lastOcclusion: false, windowIsKey: false, windowIsVisible: true, requiresVisibleWindow: false
      ))
    // Typing at a key window heals even when the window server reports covered.
    #expect(
      GhosttySurfaceView.shouldHealOcclusion(
        lastOcclusion: false, windowIsKey: true, windowIsVisible: false, requiresVisibleWindow: false
      ))
    // Pointer events additionally require a visible report.
    #expect(
      !GhosttySurfaceView.shouldHealOcclusion(
        lastOcclusion: false, windowIsKey: true, windowIsVisible: false, requiresVisibleWindow: true
      ))
    #expect(
      GhosttySurfaceView.shouldHealOcclusion(
        lastOcclusion: false, windowIsKey: true, windowIsVisible: true, requiresVisibleWindow: true
      ))
  }

  @Test func keyboardLayoutChangeKeyUpSuppressionSuppressesMatchingKeyUp() {
    let suppression = GhosttySurfaceView.KeyboardLayoutChangeKeyUpSuppression(
      keyCode: 49,
      timestamp: 10
    )

    #expect(suppression.suppresses(keyCode: 49, timestamp: 10.1))
    #expect(!suppression.isExpired(at: 10.1))
  }

  @Test func keyboardLayoutChangeKeyUpSuppressionIgnoresDifferentKeyUp() {
    let suppression = GhosttySurfaceView.KeyboardLayoutChangeKeyUpSuppression(
      keyCode: 49,
      timestamp: 10
    )

    #expect(!suppression.suppresses(keyCode: 50, timestamp: 10.1))
    #expect(suppression.suppresses(keyCode: 49, timestamp: 10.2))
    #expect(!suppression.isExpired(at: 10.1))
  }

  @Test func keyboardLayoutChangeKeyUpSuppressionExpires() {
    let suppression = GhosttySurfaceView.KeyboardLayoutChangeKeyUpSuppression(
      keyCode: 49,
      timestamp: 10
    )

    #expect(!suppression.suppresses(keyCode: 49, timestamp: 11.1))
    #expect(suppression.isExpired(at: 11.1))
  }

  private static func keyEvent(
    chars: String,
    ignoringModifiers: String,
    modifiers: NSEvent.ModifierFlags,
    keyCode: UInt16 = 4
  ) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: chars,
      charactersIgnoringModifiers: ignoringModifiers,
      isARepeat: false,
      keyCode: keyCode
    )!
  }

  private static func item(action: Selector?, keyEquivalent: String, mask: NSEvent.ModifierFlags) -> NSMenuItem {
    let item = NSMenuItem(title: "Item", action: action, keyEquivalent: keyEquivalent)
    item.keyEquivalentModifierMask = mask
    return item
  }

  private static func menu(action: Selector?, keyEquivalent: String, mask: NSEvent.ModifierFlags) -> NSMenu {
    let menu = NSMenu()
    menu.addItem(item(action: action, keyEquivalent: keyEquivalent, mask: mask))
    return menu
  }

  /// The `⌥⌘H` chord that collides with the Hide Others built-in.
  private static func optionCommandH() -> NSEvent {
    keyEvent(chars: "˙", ignoringModifiers: "h", modifiers: [.command, .option])
  }

  private static func commandV(modifiers: NSEvent.ModifierFlags = [.command]) -> NSEvent {
    keyEvent(chars: "v", ignoringModifiers: "v", modifiers: modifiers)
  }

  /// The Hide Others built-in item bound to `⌥⌘H`.
  private static func hideOthersItem() -> NSMenuItem {
    item(
      action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: "h",
      mask: [.command, .option]
    )
  }

  @Test func forwardableMenuItemSkipsHideOthersBuiltIn() {
    let menu = Self.menu(
      action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: "h",
      mask: [.command, .option]
    )

    #expect(GhosttySurfaceView.forwardableMenuItem(for: Self.optionCommandH(), in: menu) == nil)
  }

  @Test func imageOnlyCommandVRoutesForClaudeImagePaste() {
    #expect(
      GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [.tiff],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
  }

  @Test func imageCommandVDoesNotOverrideTextOrFilePaste() {
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [.string, .tiff],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [.fileURL, .tiff],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
  }

  @Test func imageCommandVRequiresExactCommandVAndSupportedAgent() {
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(modifiers: [.command, .shift]),
        pasteboardTypes: [.tiff],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [.tiff],
        imagePasteAgents: [.opencode],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
  }

  @Test func imageCommandVDoesNotInterruptGhosttyKeySequences() {
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [.tiff],
        imagePasteAgents: [.claude],
        keySequenceActive: true,
        keyTableDepth: 0
      )
    )
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [.tiff],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 1
      )
    )
  }

  @Test func imageCommandVIgnoresRichTextAndUrlRepresentations() {
    // Browser / Preview image copies carry TIFF alongside RTF, HTML, or a URL; those paste as text.
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [NSPasteboard.PasteboardType("public.rtf"), .tiff],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [NSPasteboard.PasteboardType("public.html"), .tiff],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [.URL, .tiff],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
  }

  @Test func imageCommandVRoutesForNonTiffImageType() {
    #expect(
      GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [.png],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
  }

  @Test func imageCommandVDoesNotRouteWithoutImageType() {
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: nil,
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
  }

  @Test func nativeImagePasteEventConvertsCommandVToControlV() throws {
    let converted = try #require(GhosttySurfaceView.nativeImagePasteEvent(from: Self.commandV()))

    #expect(converted.characters == "v")
    #expect(converted.charactersIgnoringModifiers == "v")
    #expect(converted.modifierFlags.intersection([.shift, .control, .option, .command]) == [.control])
  }

  @Test func forwardableMenuItemKeepsAppOwnedItem() {
    let menu = Self.menu(action: Selector(("appOwnedAction:")), keyEquivalent: "h", mask: [.command, .option])

    #expect(GhosttySurfaceView.forwardableMenuItem(for: Self.optionCommandH(), in: menu) != nil)
  }

  @Test func forwardableMenuItemSkipsHideBuiltIn() {
    let event = Self.keyEvent(chars: "h", ignoringModifiers: "h", modifiers: [.command])
    let menu = Self.menu(action: #selector(NSApplication.hide(_:)), keyEquivalent: "h", mask: [.command])

    #expect(GhosttySurfaceView.forwardableMenuItem(for: event, in: menu) == nil)
  }

  @Test func forwardableMenuItemHonorsImplicitShiftForAppOwnedItem() {
    let event = Self.keyEvent(chars: "A", ignoringModifiers: "a", modifiers: [.command, .shift])
    let menu = Self.menu(action: Selector(("appOwnedAction:")), keyEquivalent: "A", mask: [.command])

    #expect(GhosttySurfaceView.forwardableMenuItem(for: event, in: menu) != nil)
  }

  @Test func forwardableMenuItemRecursesIntoSubmenusAndSkipsBuiltIns() {
    let builtInSubmenu = NSMenu()
    builtInSubmenu.addItem(Self.hideOthersItem())
    let builtInRoot = NSMenu()
    builtInRoot.addItem(withTitle: "App", action: nil, keyEquivalent: "").submenu = builtInSubmenu
    #expect(GhosttySurfaceView.forwardableMenuItem(for: Self.optionCommandH(), in: builtInRoot) == nil)

    let appSubmenu = NSMenu()
    appSubmenu.addItem(Self.item(action: Selector(("appOwnedAction:")), keyEquivalent: "h", mask: [.command, .option]))
    let appRoot = NSMenu()
    appRoot.addItem(withTitle: "App", action: nil, keyEquivalent: "").submenu = appSubmenu
    #expect(GhosttySurfaceView.forwardableMenuItem(for: Self.optionCommandH(), in: appRoot) != nil)
  }

  @Test func forwardableMenuItemResolvesAppOwnedItemSharingChordWithBuiltIn() {
    let menu = NSMenu()
    menu.addItem(Self.hideOthersItem())
    let appOwned = Self.item(action: Selector(("appOwnedAction:")), keyEquivalent: "h", mask: [.command, .option])
    menu.addItem(appOwned)

    // The built-in is listed first, so this pins that we dispatch the app-owned item, never Hide Others.
    #expect(GhosttySurfaceView.forwardableMenuItem(for: Self.optionCommandH(), in: menu) === appOwned)
  }

  @Test func forwardableMenuItemIgnoresBuiltInWithNonMatchingMask() {
    let event = Self.keyEvent(chars: "h", ignoringModifiers: "h", modifiers: [.command])
    let menu = NSMenu()
    menu.addItem(Self.hideOthersItem())
    let appOwned = Self.item(action: Selector(("appOwnedAction:")), keyEquivalent: "h", mask: [.command])
    menu.addItem(appOwned)

    #expect(GhosttySurfaceView.forwardableMenuItem(for: event, in: menu) === appOwned)
  }

  @Test func menuHasSystemManagedConflictDetectsBuiltInSharingChord() {
    // A custom `close_surface` remapped onto ⌘M collides with Minimize, so the chord must
    // stay with Ghostty instead of forwarding (which could fire Minimize).
    let event = Self.keyEvent(chars: "m", ignoringModifiers: "m", modifiers: [.command])
    let menu = NSMenu()
    menu.addItem(Self.item(action: Selector(("appOwnedAction:")), keyEquivalent: "m", mask: [.command]))
    menu.addItem(Self.item(action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m", mask: [.command]))

    #expect(GhosttySurfaceView.menuHasSystemManagedConflict(for: event, in: menu))
  }

  @Test func menuHasSystemManagedConflictIgnoresAppOwnedOnlyChord() {
    let event = Self.keyEvent(chars: "w", ignoringModifiers: "w", modifiers: [.command])
    let menu = Self.menu(action: Selector(("appOwnedAction:")), keyEquivalent: "w", mask: [.command])

    #expect(!GhosttySurfaceView.menuHasSystemManagedConflict(for: event, in: menu))
  }

  @Test func menuHasSystemManagedConflictRecursesIntoSubmenus() {
    let submenu = NSMenu()
    submenu.addItem(Self.hideOthersItem())
    let root = NSMenu()
    root.addItem(withTitle: "App", action: nil, keyEquivalent: "").submenu = submenu

    #expect(GhosttySurfaceView.menuHasSystemManagedConflict(for: Self.optionCommandH(), in: root))
  }

  @Test func menuItemMatchesExactCommandChord() {
    let event = Self.keyEvent(chars: "w", ignoringModifiers: "w", modifiers: [.command])
    let item = Self.item(action: Selector(("appOwnedAction:")), keyEquivalent: "w", mask: [.command])

    #expect(GhosttySurfaceView.menuItem(item, matches: event))
  }

  @Test func menuItemRejectsSupersetModifierChord() {
    // `⌘,` (Settings) must not match `⌘⇧,` (Ghostty's reload_config).
    let event = Self.keyEvent(chars: ",", ignoringModifiers: ",", modifiers: [.command, .shift])
    let item = Self.item(action: Selector(("appOwnedAction:")), keyEquivalent: ",", mask: [.command])

    #expect(!GhosttySurfaceView.menuItem(item, matches: event))
  }

  @Test func menuItemRejectsEmptyKeyEquivalent() {
    let event = Self.keyEvent(chars: "w", ignoringModifiers: "w", modifiers: [.command])
    let item = Self.item(action: Selector(("appOwnedAction:")), keyEquivalent: "", mask: [.command])

    #expect(!GhosttySurfaceView.menuItem(item, matches: event))
  }

  @Test func menuItemHonorsImplicitShiftBothDirections() {
    // An uppercase `keyEquivalent` encodes shift: it matches ⌘⇧A but not plain ⌘a.
    let shiftEvent = Self.keyEvent(chars: "A", ignoringModifiers: "a", modifiers: [.command, .shift])
    let plainEvent = Self.keyEvent(chars: "a", ignoringModifiers: "a", modifiers: [.command])
    let item = Self.item(action: Selector(("appOwnedAction:")), keyEquivalent: "A", mask: [.command])

    #expect(GhosttySurfaceView.menuItem(item, matches: shiftEvent))
    #expect(!GhosttySurfaceView.menuItem(item, matches: plainEvent))
  }

  @Test func menuItemRejectsFunctionKeyItemForPlainControlChord() {
    // Window > Center is `⌃Fn C`. It must not swallow `⌃C` or its Cyrillic `⌃Ц` twin,
    // which the terminal needs as Ctrl+C.
    // `NSMenuItem` drops `.function` from a mask set in code; AppKit's own item keeps it.
    let item = FunctionMaskMenuItem(
      title: "Center", action: Selector(("appOwnedAction:")), keyEquivalent: "c")
    let latin = Self.keyEvent(
      chars: "\u{03}", ignoringModifiers: "c", modifiers: [.control], keyCode: UInt16(kVK_ANSI_C))
    let cyrillic = Self.keyEvent(
      chars: "\u{03}", ignoringModifiers: "ц", modifiers: [.control], keyCode: UInt16(kVK_ANSI_C))
    let withFunction = Self.keyEvent(
      chars: "c", ignoringModifiers: "c", modifiers: [.control, .function], keyCode: UInt16(kVK_ANSI_C))

    #expect(!GhosttySurfaceView.menuItem(item, matches: latin))
    #expect(!GhosttySurfaceView.menuItem(item, matches: cyrillic))
    #expect(GhosttySurfaceView.menuItem(item, matches: withFunction))
  }

  @Test func menuItemMatchesPhysicalKeyWhenCharactersAreNotTheEquivalent() {
    let event = Self.keyEvent(
      chars: "т",
      ignoringModifiers: "т",
      modifiers: [.command],
      keyCode: UInt16(kVK_ANSI_T)
    )
    let item = Self.item(action: Selector(("appOwnedAction:")), keyEquivalent: "t", mask: [.command])

    #expect(GhosttySurfaceView.menuItem(item, matches: event))
    #expect(!GhosttySurfaceView.menuItemMatchesProducedCharacter(item, event: event))
  }

  @Test func dispatchForwardableChordFiresPhysicalMatchDirectly() {
    let target = MenuActionTarget()
    let event = Self.keyEvent(
      chars: "т",
      ignoringModifiers: "т",
      modifiers: [.command],
      keyCode: UInt16(kVK_ANSI_T)
    )
    let menu = NSMenu()
    menu.autoenablesItems = false
    let item = NSMenuItem(title: "New Tab", action: #selector(MenuActionTarget.fire(_:)), keyEquivalent: "t")
    item.keyEquivalentModifierMask = [.command]
    item.target = target
    item.isEnabled = true
    menu.addItem(item)

    #expect(GhosttySurfaceView.dispatchForwardableChord(item, for: event, in: menu))
    #expect(target.fired)
  }

  @Test func physicalShortcutDispatchConsumesOnlyAPhysicalMenuMatch() {
    let target = MenuActionTarget()
    let menu = NSMenu()
    menu.autoenablesItems = false
    let item = NSMenuItem(title: "New Tab", action: #selector(MenuActionTarget.fire(_:)), keyEquivalent: "t")
    item.keyEquivalentModifierMask = [.command]
    item.target = target
    item.isEnabled = true
    menu.addItem(item)
    let physical = Self.keyEvent(
      chars: "т",
      ignoringModifiers: "т",
      modifiers: [.command],
      keyCode: UInt16(kVK_ANSI_T)
    )
    let latin = Self.keyEvent(chars: "t", ignoringModifiers: "t", modifiers: [.command], keyCode: UInt16(kVK_ANSI_T))
    let responder = NSView()

    #expect(
      GhosttySurfaceView.eventAfterPhysicalShortcutDispatch(physical, firstResponder: responder, menu: menu) == nil
    )
    #expect(target.fired)
    target.fired = false
    #expect(
      GhosttySurfaceView.eventAfterPhysicalShortcutDispatch(latin, firstResponder: responder, menu: menu) === latin
    )
    #expect(!target.fired)
  }

  @Test func physicalShortcutDispatchLeavesTheShortcutRecorderAlone() {
    let recorder = HotkeyRecorderNSView()
    let event = Self.keyEvent(
      chars: "т",
      ignoringModifiers: "т",
      modifiers: [.command],
      keyCode: UInt16(kVK_ANSI_T)
    )
    let menu = NSMenu()
    let item = NSMenuItem(title: "New Tab", action: Selector(("appOwnedAction:")), keyEquivalent: "t")
    item.keyEquivalentModifierMask = [.command]
    menu.addItem(item)

    #expect(
      GhosttySurfaceView.eventAfterPhysicalShortcutDispatch(event, firstResponder: recorder, menu: menu) === event
    )
  }

  private final class MenuActionTarget: NSObject {
    var fired = false

    nonisolated deinit {}

    @objc func fire(_ sender: Any?) { fired = true }
  }

  @Test func performMenuItemDispatchesEnabledItem() {
    let target = MenuActionTarget()
    let item = NSMenuItem(title: "Go", action: #selector(MenuActionTarget.fire(_:)), keyEquivalent: "")
    item.target = target
    item.isEnabled = true

    #expect(GhosttySurfaceView.performMenuItem(item))
    #expect(target.fired)
  }

  @Test func performMenuItemRejectsDisabledItem() {
    let target = MenuActionTarget()
    let item = NSMenuItem(title: "Off", action: #selector(MenuActionTarget.fire(_:)), keyEquivalent: "")
    item.target = target
    item.isEnabled = false

    #expect(!GhosttySurfaceView.performMenuItem(item))
    #expect(!target.fired)
  }

  @Test func performMenuItemRejectsItemWithoutAction() {
    let item = NSMenuItem(title: "Inert", action: nil, keyEquivalent: "")
    item.isEnabled = true

    #expect(!GhosttySurfaceView.performMenuItem(item))
  }

  @Test func dispatchForwardableChordFiresResolvedItemDirectlyOnConflict() {
    // A custom `close_surface` on ⌘M shares the chord with Minimize: dispatch must fire the resolved
    // app item directly (so its explicit-close action runs) instead of the native path, which could
    // fire Minimize.
    let target = MenuActionTarget()
    let event = Self.keyEvent(chars: "m", ignoringModifiers: "m", modifiers: [.command])
    let menu = NSMenu()
    menu.autoenablesItems = false
    let appItem = NSMenuItem(title: "Close", action: #selector(MenuActionTarget.fire(_:)), keyEquivalent: "m")
    appItem.keyEquivalentModifierMask = [.command]
    appItem.target = target
    appItem.isEnabled = true
    menu.addItem(appItem)
    menu.addItem(Self.item(action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m", mask: [.command]))

    #expect(GhosttySurfaceView.dispatchForwardableChord(appItem, for: event, in: menu))
    #expect(target.fired)
  }

  // MARK: - Scan picks what AppKit's native key-equivalent path would pick (R32).

  /// A `⌘W` item on the US key, the way SwiftUI builds a command item.
  private static func commandWItem(target: MenuActionTarget?, enabled: Bool = true) -> NSMenuItem {
    let item = NSMenuItem(title: "Close", action: #selector(MenuActionTarget.fire(_:)), keyEquivalent: "w")
    item.keyEquivalentModifierMask = [.command]
    item.target = target
    item.isEnabled = enabled
    return item
  }

  /// `⌘W` typed on the Bulgarian layout: the W key produces `ц`.
  private static func cyrillicCommandW() -> NSEvent {
    keyEvent(chars: "ц", ignoringModifiers: "ц", modifiers: [.command], keyCode: UInt16(kVK_ANSI_W))
  }

  private static func manualMenu(_ items: [NSMenuItem]) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    items.forEach(menu.addItem)
    return menu
  }

  @Test func forwardableMenuItemSkipsDisabledMatchBeforeEnabledOne() {
    let disabled = Self.commandWItem(target: MenuActionTarget(), enabled: false)
    let enabled = Self.commandWItem(target: MenuActionTarget())
    let menu = Self.manualMenu([disabled, enabled])

    #expect(GhosttySurfaceView.forwardableMenuItem(for: Self.cyrillicCommandW(), in: menu) === enabled)
  }

  @Test func forwardableMenuItemSkipsActionlessMatchBeforeEnabledOne() {
    // A disabled SwiftUI command item drops its action.
    let actionless = Self.commandWItem(target: nil)
    actionless.action = nil
    let enabled = Self.commandWItem(target: MenuActionTarget())
    let menu = Self.manualMenu([actionless, enabled])

    #expect(GhosttySurfaceView.forwardableMenuItem(for: Self.cyrillicCommandW(), in: menu) === enabled)
  }

  @Test func forwardableMenuItemSkipsHiddenMatchBeforeEnabledOne() {
    let hidden = Self.commandWItem(target: MenuActionTarget())
    hidden.isHidden = true
    let visible = Self.commandWItem(target: MenuActionTarget())
    let menu = Self.manualMenu([hidden, visible])

    #expect(GhosttySurfaceView.forwardableMenuItem(for: Self.cyrillicCommandW(), in: menu) === visible)
  }

  @Test func forwardableMenuItemKeepsHiddenItemThatAllowsItsKeyEquivalent() {
    let hidden = Self.commandWItem(target: MenuActionTarget())
    hidden.isHidden = true
    hidden.allowsKeyEquivalentWhenHidden = true
    let menu = Self.manualMenu([hidden])

    #expect(GhosttySurfaceView.forwardableMenuItem(for: Self.cyrillicCommandW(), in: menu) === hidden)
  }

  @Test func forwardableMenuItemSkipsTheSubmenuOfAHiddenParent() {
    let nested = Self.commandWItem(target: MenuActionTarget())
    let hiddenParent = NSMenuItem(title: "Hidden", action: nil, keyEquivalent: "")
    hiddenParent.isHidden = true
    hiddenParent.submenu = Self.manualMenu([nested])
    let visible = Self.commandWItem(target: MenuActionTarget())
    let menu = Self.manualMenu([hiddenParent, visible])

    #expect(GhosttySurfaceView.forwardableMenuItem(for: Self.cyrillicCommandW(), in: menu) === visible)
  }

  @Test func forwardableMenuItemSkipsDisabledMatchInAnEarlierSubmenu() {
    let fileMenu = Self.manualMenu([Self.commandWItem(target: MenuActionTarget(), enabled: false)])
    let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
    fileItem.submenu = fileMenu
    let enabled = Self.commandWItem(target: MenuActionTarget())
    let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
    windowItem.submenu = Self.manualMenu([enabled])
    let root = Self.manualMenu([fileItem, windowItem])

    #expect(GhosttySurfaceView.forwardableMenuItem(for: Self.cyrillicCommandW(), in: root) === enabled)
  }

  @Test func forwardableMenuItemFallsBackToTheFirstDisabledMatch() {
    // No enabled candidate: keep today's answer so a Latin chord still reaches
    // the native path, which validates the item itself.
    let disabled = Self.commandWItem(target: MenuActionTarget(), enabled: false)
    let menu = Self.manualMenu([disabled])

    #expect(GhosttySurfaceView.forwardableMenuItem(for: Self.cyrillicCommandW(), in: menu) === disabled)
  }

  @Test func physicalShortcutDispatchFiresTheEnabledItemPastADisabledOne() {
    let disabledTarget = MenuActionTarget()
    let enabledTarget = MenuActionTarget()
    let menu = Self.manualMenu([
      Self.commandWItem(target: disabledTarget, enabled: false),
      Self.commandWItem(target: enabledTarget),
    ])

    #expect(
      GhosttySurfaceView.eventAfterPhysicalShortcutDispatch(
        Self.cyrillicCommandW(), firstResponder: NSView(), menu: menu) == nil
    )
    #expect(enabledTarget.fired)
    #expect(!disabledTarget.fired)
  }

  @Test func forwardedCyrillicChordFiresTheEnabledItemPastAHiddenOne() {
    // The terminal path: scan, then dispatch (a physical-only match fires directly).
    let hiddenTarget = MenuActionTarget()
    let hidden = Self.commandWItem(target: hiddenTarget)
    hidden.isHidden = true
    let enabledTarget = MenuActionTarget()
    let menu = Self.manualMenu([hidden, Self.commandWItem(target: enabledTarget)])
    let event = Self.cyrillicCommandW()

    let item = GhosttySurfaceView.forwardableMenuItem(for: event, in: menu)
    #expect(item.map { GhosttySurfaceView.dispatchForwardableChord($0, for: event, in: menu) } == true)
    #expect(enabledTarget.fired)
    #expect(!hiddenTarget.fired)
  }

  /// Stands in for SwiftUI's command menus: their delegate (`AppKitMainMenuItem`) fills the items
  /// with the current focused actions in `menuNeedsUpdate(_:)`, which AppKit's own key-equivalent
  /// path calls first. Here it swaps in a fresh item.
  private final class RebuildingMenuDelegate: NSObject, NSMenuDelegate {
    let fresh: NSMenuItem
    var refreshes = 0

    init(fresh: NSMenuItem) {
      self.fresh = fresh
    }

    nonisolated deinit {}

    func menuNeedsUpdate(_ menu: NSMenu) {
      refreshes += 1
      menu.removeAllItems()
      menu.addItem(fresh)
    }
  }

  /// A Cyrillic ⌘W fires its item directly, which AppKit's own path would refresh first. Without
  /// the refresh it ran the action of an older focus: the main window's Close Tab while the Remote
  /// Mac window was key, or ⌘D with the pane focused before (ХП1, ХП3).
  @Test func directlyFiredChordUpdatesTheMenuAndFiresTheFreshItem() {
    let staleTarget = MenuActionTarget()
    let freshTarget = MenuActionTarget()
    let stale = Self.commandWItem(target: staleTarget)
    let fileMenu = Self.manualMenu([stale])
    let delegate = RebuildingMenuDelegate(fresh: Self.commandWItem(target: freshTarget))
    fileMenu.delegate = delegate
    let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
    fileItem.submenu = fileMenu
    let root = Self.manualMenu([fileItem])
    let event = Self.cyrillicCommandW()

    #expect(GhosttySurfaceView.dispatchForwardableChord(stale, for: event, in: root))
    #expect(delegate.refreshes == 1)
    #expect(freshTarget.fired)
    #expect(!staleTarget.fired)
  }

  @Test func isSystemManagedMenuItemClassifiesActions() {
    let hideOthers = NSMenuItem(
      title: "Hide Others",
      action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: ""
    )
    #expect(GhosttySurfaceView.isSystemManagedMenuItem(hideOthers))

    let appOwned = NSMenuItem(title: "Custom", action: Selector(("appOwnedAction:")), keyEquivalent: "")
    #expect(!GhosttySurfaceView.isSystemManagedMenuItem(appOwned))

    let noAction = NSMenuItem(title: "Inert", action: nil, keyEquivalent: "")
    #expect(!GhosttySurfaceView.isSystemManagedMenuItem(noAction))
  }

  @Test func reportedSurfaceSizeUsesScrollContentWidth() {
    #expect(
      GhosttySurfaceScrollView.reportedSurfaceSize(
        scrollContentSize: CGSize(width: 799, height: 600),
        surfaceFrameSize: CGSize(width: 816, height: 600)
      ) == CGSize(width: 799, height: 600)
    )
  }

  @Test func wrapperSafeAreaInsetsAreZero() {
    let surfaceView = GhosttySurfaceView(
      id: UUID(),
      runtime: GhosttyRuntime(),
      workingDirectory: nil,
      initialGeometry: .fallback,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
    defer { surfaceView.closeSurface() }
    let wrapper = GhosttySurfaceScrollView(surfaceView: surfaceView)

    #expect(wrapper.safeAreaInsets.top == 0)
    #expect(wrapper.safeAreaInsets.left == 0)
    #expect(wrapper.safeAreaInsets.bottom == 0)
    #expect(wrapper.safeAreaInsets.right == 0)
  }

  // A remount must reparent the same wrapper, so the live IOSurface keeps its
  // frames instead of the renderer rebuilding at zero size on every switch.
  @Test func hostedViewReturnsTheSameWrapperAcrossRemounts() {
    let surfaceView = GhosttySurfaceView(
      id: UUID(),
      runtime: GhosttyRuntime(),
      workingDirectory: nil,
      initialGeometry: .fallback,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
    defer { surfaceView.closeSurface() }

    let wrapper = surfaceView.hostedView()
    #expect(surfaceView.hostedView() === wrapper)
    // The reuse guard in the content host keys off `scrollWrapper`; it has to
    // point at the very wrapper `hostedView()` vends.
    #expect(surfaceView.scrollWrapper === wrapper)
  }

  // `closeSurface` must clear the cached wrapper so the surface<->wrapper cycle
  // is broken: proven by `hostedView()` vending a fresh instance afterwards. If
  // the release is ever dropped, the same wrapper comes back and both leak.
  @Test func closeSurfaceClearsTheCachedWrapper() {
    let surfaceView = GhosttySurfaceView(
      id: UUID(),
      runtime: GhosttyRuntime(),
      workingDirectory: nil,
      initialGeometry: .fallback,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
    defer { surfaceView.closeSurface() }

    let first = surfaceView.hostedView()
    surfaceView.closeSurface()
    let second = surfaceView.hostedView()

    #expect(first !== second)
    #expect(surfaceView.scrollWrapper === second)
  }

  // `closeSurface` detaches synchronously (surface cleared, view hidden so the
  // "[Process exited]" overlay can't flash during a collapse) and defers the
  // costly `ghostty_surface_free` off the turn, and a second close is a safe
  // no-op. Only the hide needs a live renderer, absent when the display sleeps;
  // the synchronous clear and the double-close no-op hold on both paths.
  @Test func closeSurfaceDetachesSynchronouslyAndHidesTheView() {
    let surfaceView = GhosttySurfaceView(
      id: UUID(),
      runtime: GhosttyRuntime(),
      workingDirectory: nil,
      initialGeometry: .fallback,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
    let hadLiveRenderer = surfaceView.surface != nil

    surfaceView.closeSurface()
    #expect(surfaceView.surface == nil)
    if hadLiveRenderer {
      #expect(surfaceView.isHidden)
    }

    // Idempotent: the surface is already gone, so this must not double-free.
    surfaceView.closeSurface()
    #expect(surfaceView.surface == nil)
  }
}

private nonisolated final class FunctionMaskMenuItem: NSMenuItem {
  override var keyEquivalentModifierMask: NSEvent.ModifierFlags {
    get { [.control, .function] }
    set {}
  }
}
