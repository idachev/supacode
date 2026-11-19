import Foundation
import SupacodeSettingsShared

nonisolated private let remoteWindowsLogger = SupaLogger("RemoteClient")

/// The value a remote window is opened for. `nil` hostID: a new window that shows the picker.
nonisolated struct RemoteClientWindowValue: Codable, Hashable, Sendable {
  var hostID: String?

  /// What "Open Remote Mac…" opens (R29): with no remote window open, the Mac picked last (the
  /// one-Mac flow), else a new window with the picker.
  static func toOpen(hasOpenWindows: Bool, saved: String?) -> RemoteClientWindowValue {
    RemoteClientWindowValue(hostID: hasOpenWindows ? nil : saved)
  }
}

/// One open remote window, as the registry reaches it.
@MainActor
protocol RemoteClientWindowHandle: AnyObject {
  /// The Macs the other remote windows show changed.
  func otherWindowsChanged(_ hostIDs: Set<String>)
  /// A tap on a notification of the Mac this window shows; the window is already in front.
  func notificationOpened(_ target: RemoteClientNotifier.Target)
  func bringForward()
  /// The window closed: disconnects its Mac (КЛ6) and lets its last notification removals land.
  func close() async
  /// The app quits: stops the session now, with no effect left to run (R30).
  func closeNow()
}

/// Every open remote window of the app, one per Mac. The Mac a window shows is claimed here, so no
/// Mac is ever open in two windows; a notification tap, "Open Remote Mac…" and the in-window
/// switch all bring forward the window that already shows a Mac. Ids only: never a Mac's name.
@MainActor
final class RemoteClientWindowRegistry {
  static let shared = RemoteClientWindowRegistry()

  /// Opens a new remote window; set by a view that can reach SwiftUI's `openWindow`.
  var openWindow: ((RemoteClientWindowValue) -> Void)?

  private struct Entry {
    let handle: any RemoteClientWindowHandle
    var hostID: String?
    /// The other windows' Macs as this window was last told them.
    var told: Set<String>?
  }

  /// Open windows in the order they opened.
  private var entries: [(id: UUID, entry: Entry)] = []
  /// Closed windows whose close has not finished: kept alive, and stopped too on quit.
  private var closing: [UUID: any RemoteClientWindowHandle] = [:]

  nonisolated deinit {}

  var hasOpenWindows: Bool { !entries.isEmpty }

  /// Joins a window that appeared; again for one already in, nothing changes.
  func register(_ window: UUID, handle: any RemoteClientWindowHandle) {
    guard index(of: window) == nil else { return }
    closing[window] = nil
    entries.append((window, Entry(handle: handle, hostID: nil, told: nil)))
    broadcast()
  }

  /// Takes the Mac for the window; false when another remote window shows it.
  func claim(_ hostID: String, for window: UUID) -> Bool {
    guard let index = index(of: window) else { return false }
    if entries.contains(where: { $0.id != window && $0.entry.hostID == hostID }) { return false }
    guard entries[index].entry.hostID != hostID else { return true }
    entries[index].entry.hostID = hostID
    broadcast()
    return true
  }

  /// The window closed: it gives up its Mac at once and is kept until its close has run. The close
  /// starts before this returns, so a window that appears again right after reconnects after it.
  func windowClosed(_ window: UUID) {
    guard let index = index(of: window) else { return }
    let handle = entries.remove(at: index).entry.handle
    broadcast()
    closing[window] = handle
    Task.immediate { [weak self] in
      await handle.close()
      if self?.closing[window] === handle { self?.closing[window] = nil }
    }
  }

  /// Brings forward the window that shows the Mac; false when none does.
  @discardableResult
  func focus(_ hostID: String) -> Bool {
    guard let handle = handle(showing: hostID) else { return false }
    handle.bringForward()
    return true
  }

  /// File ▸ "Open Remote Mac…" (R29).
  func openRemoteMac(saved: String?) {
    let value = RemoteClientWindowValue.toOpen(hasOpenWindows: hasOpenWindows, saved: saved)
    if let hostID = value.hostID, focus(hostID) { return }
    open(value)
  }

  /// A notification tap (ИВ3): the window of its Mac, brought forward, selects the tab; with no
  /// window for that Mac, one opens for it (its tab is not selected: the new window has no list yet).
  func notificationOpened(_ target: RemoteClientNotifier.Target) {
    guard let handle = handle(showing: target.hostID) else {
      remoteWindowsLogger.info("Remote notification tap for a Mac with no window: opening one")
      open(RemoteClientWindowValue(hostID: target.hostID))
      return
    }
    handle.bringForward()
    handle.notificationOpened(target)
  }

  /// App quit (R30): every session stops now, also of windows still closing.
  func closeAll() {
    for handle in entries.map(\.entry.handle) + Array(closing.values) {
      handle.closeNow()
    }
  }

  private func open(_ value: RemoteClientWindowValue) {
    guard let openWindow else {
      remoteWindowsLogger.warning("Cannot open a remote window: no window opener")
      return
    }
    openWindow(value)
  }

  private func index(of window: UUID) -> Int? {
    entries.firstIndex { $0.id == window }
  }

  private func handle(showing hostID: String) -> (any RemoteClientWindowHandle)? {
    entries.first { $0.entry.hostID == hostID }?.entry.handle
  }

  /// Tells each window the Macs the others show, when that changed for it.
  private func broadcast() {
    for index in entries.indices {
      let id = entries[index].id
      let others = Set(entries.lazy.filter { $0.id != id }.compactMap(\.entry.hostID))
      guard entries[index].entry.told != others else { continue }
      entries[index].entry.told = others
      entries[index].entry.handle.otherWindowsChanged(others)
    }
  }
}
