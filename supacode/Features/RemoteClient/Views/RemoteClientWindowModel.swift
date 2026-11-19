import ComposableArchitecture
import SwiftUI

/// The store and the session behind the "Remote Mac" window. One per app: the `Window` scene's
/// views go away when it closes, but the session must outlive that to close itself
/// (`windowClosed`), and the next opening reuses both (КЛ6: connected only while open).
@MainActor
final class RemoteClientWindowModel {
  private static var shared: RemoteClientWindowModel?

  let session: RemoteClientSession
  let store: StoreOf<RemoteClientFeature>

  private init(ghostty: GhosttyRuntime) {
    let session = RemoteClientSession(ghostty: ghostty)
    self.session = session
    store = Store(initialState: RemoteClientFeature.State()) {
      RemoteClientFeature()
    } withDependencies: {
      $0.remoteClientSession = .live(session)
    }
  }

  nonisolated deinit {}

  static func shared(ghostty: GhosttyRuntime) -> RemoteClientWindowModel {
    if let shared { return shared }
    let model = RemoteClientWindowModel(ghostty: ghostty)
    shared = model
    return model
  }
}

/// The `Window` scene's root: connects when the window appears, disconnects when it closes.
struct RemoteClientWindowRoot: View {
  let ghostty: GhosttyRuntime
  @State private var model: RemoteClientWindowModel?

  var body: some View {
    Group {
      if let model {
        RemoteClientWindowView(store: model.store, session: model.session, ghostty: ghostty)
      } else {
        Color.clear
      }
    }
    .frame(minWidth: 480, minHeight: 320)
    .background {
      // Key or not decides whether a waiting tab it shows posts a notification (ИВ2).
      // Through `shared`: the first report can come before `onAppear` sets `model`.
      WindowFocusObserverView { [ghostty] activity in
        RemoteClientWindowModel.shared(ghostty: ghostty).store.send(.windowKeyChanged(activity.isKeyWindow))
      }
      RemoteClientWindowAnchor()
    }
    .onAppear {
      let model = RemoteClientWindowModel.shared(ghostty: ghostty)
      self.model = model
      RemoteClientNotificationRouter.shared.store = model.store
      model.store.send(.windowAppeared)
    }
    .onDisappear {
      RemoteClientNotificationRouter.shared.store = nil
      RemoteClientWindowModel.shared(ghostty: ghostty).store.send(.windowClosed)
    }
  }
}
