import AppKit
import ComposableArchitecture
import Observation
import SwiftUI

/// The store and the session behind one "Remote Mac" window. The window's views go away when it
/// closes, but the session must outlive them to close itself (`windowClosed`, КЛ6) and to hand its
/// last notification removals to the center: the registry keeps the model until then.
@MainActor
final class RemoteClientWindowModel: RemoteClientWindowHandle {
  /// The window's key in `RemoteClientWindowRegistry`.
  let id: UUID
  let session: RemoteClientSession
  let store: StoreOf<RemoteClientFeature>
  /// Set by the window's anchor, so a notification tap can bring it forward.
  weak var window: NSWindow?

  init(ghostty: GhosttyRuntime, hostID: String?, registry: RemoteClientWindowRegistry = .shared) {
    let id = UUID()
    let session = RemoteClientSession(ghostty: ghostty)
    self.id = id
    self.session = session
    // The one place a remote window's store is made. Both clients must be bound to this window:
    // the default session client connects nothing, and the default windows client lets this window
    // claim every Mac (each logs an error when reached).
    store = Store(initialState: RemoteClientFeature.State(selectedHostID: hostID)) {
      RemoteClientFeature()
    } withDependencies: {
      $0.remoteClientSession = .live(session)
      $0.remoteClientWindows = .live(registry, window: id)
    }
  }

  nonisolated deinit {}

  func otherWindowsChanged(_ hostIDs: Set<String>) {
    store.send(.otherWindowsChanged(hostIDs))
  }

  func notificationOpened(_ target: RemoteClientNotifier.Target) {
    store.send(.notificationOpened(hostID: target.hostID, worktreeID: target.worktreeID, contentID: target.contentID))
  }

  var relayListsNoHosts: Bool {
    session.connection?.relayListsNoHosts == true
  }

  func bringForward() {
    if let window {
      if window.isMiniaturized { window.deminiaturize(nil) }
      window.makeKeyAndOrderFront(nil)
    }
    NSApplication.shared.activate()
  }

  /// Sends `windowClosed` before its first suspension, then waits for its effects (the session's
  /// close) and for the notification queue to drain.
  func close() async {
    await store.send(.windowClosed).finish()
    while store.withState(\.isDeliveringNotifications) {
      await withCheckedContinuation { continuation in
        withObservationTracking {
          _ = store.isDeliveringNotifications
        } onChange: {
          continuation.resume()
        }
      }
    }
  }

  /// The app quits: no effect would run any more, so the session stops here (R30).
  func closeNow() {
    session.close()
  }
}

/// The root of one window of the "Remote Mac" `WindowGroup`: makes the window's model for the Mac
/// it was opened for, joins the registry and connects when it appears, and leaves when it closes.
/// The window's value follows the Mac it shows, so "the window of this Mac" stays findable.
struct RemoteClientWindowRoot: View {
  @Binding var value: RemoteClientWindowValue?
  let ghostty: GhosttyRuntime
  @State private var model: RemoteClientWindowModel?

  var body: some View {
    Group {
      if let model {
        RemoteClientWindowView(store: model.store, session: model.session, ghostty: ghostty)
          .background {
            // Key or not decides whether a waiting tab it shows posts a notification (ИВ2).
            WindowFocusObserverView { activity in
              model.store.send(.windowKeyChanged(activity.isKeyWindow))
            }
            RemoteClientWindowAnchor { window in
              model.window = window
            }
          }
          .onChange(of: model.store.selectedHostID, initial: true) { _, hostID in
            let shown = RemoteClientWindowValue(hostID: hostID)
            if value != shown { value = shown }
          }
      } else {
        Color.clear
      }
    }
    .frame(minWidth: 480, minHeight: 320)
    .onAppear {
      let model = self.model ?? RemoteClientWindowModel(ghostty: ghostty, hostID: value?.hostID)
      self.model = model
      RemoteClientWindowRegistry.shared.register(model.id, handle: model)
      model.store.send(.windowAppeared)
    }
    .onDisappear {
      guard let model else { return }
      RemoteClientWindowRegistry.shared.windowClosed(model.id)
    }
  }
}
