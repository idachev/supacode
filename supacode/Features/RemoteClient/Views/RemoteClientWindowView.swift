import AppKit
import ComposableArchitecture
import SupacodeSettingsShared
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
        RemoteClientWindowView(store: model.store, session: model.session)
      } else {
        Color.clear
      }
    }
    .frame(minWidth: 480, minHeight: 320)
    .onAppear {
      let model = RemoteClientWindowModel.shared(ghostty: ghostty)
      self.model = model
      model.store.send(.windowAppeared)
    }
    .onDisappear {
      RemoteClientWindowModel.shared(ghostty: ghostty).store.send(.windowClosed)
    }
  }
}

/// The remote window (ПЗ1, ПЗ2): the Mac's name and path as the title, the worktrees of its last
/// `list` in the sidebar and the selected worktree's first tab as a live terminal.
struct RemoteClientWindowView: View {
  @Bindable var store: StoreOf<RemoteClientFeature>
  let session: RemoteClientSession

  var body: some View {
    content
      .toolbar(removing: .title)
      .navigationTitle(store.macName)
      .toolbar {
        ToolbarItem(placement: .navigation) {
          RemoteClientTitleButton(name: store.macName, detail: store.status.pathText) {
            store.send(.titleTapped)
          }
          .disabled(!store.hasKeyFile)
        }
      }
      .sheet(
        isPresented: Binding(
          get: { store.isHostPickerPresented },
          set: { if !$0 { store.send(.hostPickerDismissed) } }
        )
      ) {
        RemoteHostPickerView(
          hosts: store.pickableHosts,
          selectedHostID: store.selectedHostID,
          onPick: { store.send(.hostPicked($0)) },
          onCancel: { store.send(.hostPickerDismissed) }
        )
      }
  }

  @ViewBuilder private var content: some View {
    if !store.hasKeyFile {
      RemoteClientNoKeyView { store.send(.windowAppeared) }
    } else {
      switch store.status {
      case .unsupportedHost:
        ContentUnavailableView {
          Label("\(store.macName) runs an older Supacode", systemImage: "exclamationmark.triangle")
        } description: {
          Text("Update Supacode on that Mac to open it from here.")
        }
      case .failed(let message):
        ContentUnavailableView {
          Label("Cannot connect to \(store.macName)", systemImage: "wifi.exclamationmark")
        } description: {
          Text(message)
        } actions: {
          Button("Try Again") { store.send(.windowAppeared) }
            .help("Connect to the Mac again")
        }
      default:
        if store.list != nil {
          RemoteClientSplitView(store: store, session: session)
        } else {
          RemoteClientWaitingView(store: store)
        }
      }
    }
  }
}

/// The window title: the Mac's name over the path in use. Clicking it opens the Mac picker.
private struct RemoteClientTitleButton: View {
  let name: String
  let detail: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 0) {
        Text(name)
          .font(.headline)
        if !detail.isEmpty {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .buttonStyle(.plain)
    .help("Choose which Mac this window shows")
  }
}

/// No connection key file (КЛ1): how to add one. Never shows the relay address or the key.
private struct RemoteClientNoKeyView: View {
  let onCheckAgain: () -> Void

  private var keyPath: String {
    (RemoteAccessConfig.clientKeyFileURL.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
  }

  var body: some View {
    ContentUnavailableView {
      Label("No connection key", systemImage: "key")
    } description: {
      VStack(spacing: 8) {
        Text("Copy remote-client-key.txt from a Mac that shares its Supacode to this path:")
        Text(keyPath)
          .monospaced()
          .textSelection(.enabled)
        Text("Then make it readable only by you: chmod 600 \(keyPath)")
      }
    } actions: {
      Button("Check Again", action: onCheckAgain)
        .help("Look for the connection key file again")
    }
  }
}

/// Connected or connecting, with no `list` yet.
private struct RemoteClientWaitingView: View {
  let store: StoreOf<RemoteClientFeature>

  var body: some View {
    switch store.status {
    case .hostOffline:
      ContentUnavailableView(
        "\(store.macName) is offline",
        systemImage: "desktopcomputer.trianglebadge.exclamationmark",
        description: Text("The window connects again when the Mac comes back.")
      )
    case .choosingHost:
      ContentUnavailableView {
        Label("Choose a Mac", systemImage: "desktopcomputer")
      } actions: {
        Button("Choose Mac…") { store.send(.titleTapped) }
          .help("Choose which Mac this window shows")
      }
    default:
      ProgressView("Connecting to \(store.macName)…")
    }
  }
}

/// The worktrees of the Mac's `list` and the selected one's first tab.
private struct RemoteClientSplitView: View {
  let store: StoreOf<RemoteClientFeature>
  let session: RemoteClientSession

  var body: some View {
    NavigationSplitView {
      List(
        selection: Binding(
          get: { store.selectedWorktreeID },
          set: { id in if let id { store.send(.worktreeSelected(id)) } }
        )
      ) {
        ForEach(store.worktrees) { worktree in
          Text(worktree.name.isEmpty ? worktree.branch : worktree.name)
            .tag(worktree.id)
        }
      }
      .navigationSplitViewColumnWidth(min: 180, ideal: 220)
    } detail: {
      if let worktree = store.selectedWorktree, let tab = worktree.tabs.first {
        RemoteTabDetailView(session: session, tab: tab, macName: store.macName)
      } else {
        ContentUnavailableView("No terminal", systemImage: "terminal")
          // No tab shown: nothing stays attached.
          .task(id: session.epoch) { session.releaseAll(except: nil) }
      }
    }
  }
}

/// One remote tab: its live surface, or why there is none.
private struct RemoteTabDetailView: View {
  let session: RemoteClientSession
  let tab: RemoteClientTab
  let macName: String
  @State private var content: RemoteTerminalContent?

  private struct Key: Hashable {
    let contentID: String
    let epoch: Int
  }

  var body: some View {
    Group {
      if tab.contentId.isEmpty {
        ContentUnavailableView("No terminal", systemImage: "terminal")
      } else if let content, content.remoteContentID == tab.contentId {
        if case .ended(let reason) = content.phase {
          ContentUnavailableView(
            "This terminal ended on \(macName)", systemImage: "terminal", description: Text(reason))
        } else if content.sessionFailedToStart {
          ContentUnavailableView("The terminal could not start", systemImage: "exclamationmark.triangle")
        } else {
          RemoteTerminalHostView(content: content)
        }
      } else {
        ProgressView()
      }
    }
    // Made outside the body: making a content starts its surface. A new epoch (another Mac, a
    // reconnect from the window) tore the old content down.
    .task(id: Key(contentID: tab.contentId, epoch: session.epoch)) {
      // One tab shown at a time in this window: every other one lets go of the Mac.
      guard !tab.contentId.isEmpty else {
        session.releaseAll(except: nil)
        return
      }
      content = session.content(for: tab.contentId, title: tab.title)
      session.releaseAll(except: tab.contentId)
    }
  }
}

/// Mounts a remote surface. The parent clips and is flipped, so the surface can later be given
/// a fixed frame anchored top left (ТР8а) without touching `GhosttySurfaceView`.
private struct RemoteTerminalHostView: NSViewRepresentable {
  let content: RemoteTerminalContent

  func makeNSView(context: Context) -> RemoteTerminalContainerView {
    let container = RemoteTerminalContainerView()
    container.mount(content.renderer as? GhosttySurfaceView)
    return container
  }

  func updateNSView(_ container: RemoteTerminalContainerView, context: Context) {
    container.mount(content.renderer as? GhosttySurfaceView)
  }
}

final class RemoteTerminalContainerView: NSView {
  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    clipsToBounds = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  nonisolated deinit {}

  func mount(_ surface: GhosttySurfaceView?) {
    guard let surface else {
      subviews.forEach { $0.removeFromSuperview() }
      return
    }
    // The surface's own scroll wrapper, as a local pane mounts it: it owns the surface's frame.
    let hosted = surface.hostedView()
    guard hosted.superview !== self else { return }
    subviews.forEach { $0.removeFromSuperview() }
    hosted.translatesAutoresizingMaskIntoConstraints = false
    addSubview(hosted)
    NSLayoutConstraint.activate([
      hosted.leadingAnchor.constraint(equalTo: leadingAnchor),
      hosted.trailingAnchor.constraint(equalTo: trailingAnchor),
      hosted.topAnchor.constraint(equalTo: topAnchor),
      hosted.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    surface.requestFocus()
  }
}

/// The Mac picker: every Mac on the relay but this one, with an online dot.
private struct RemoteHostPickerView: View {
  let hosts: [RemoteClientHostInfo]
  let selectedHostID: String?
  let onPick: (String) -> Void
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Choose a Mac")
        .font(.headline)
      if hosts.isEmpty {
        Text("No other Mac shares its Supacode on this relay.")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(hosts) { host in
          let name = host.name ?? "Unnamed Mac"
          Button {
            onPick(host.id)
          } label: {
            HStack {
              Image(systemName: "circle.fill")
                .imageScale(.small)
                .foregroundStyle(host.online ? Color.green : Color.secondary)
                .accessibilityLabel(host.online ? "Online" : "Offline")
              Text(name)
              Spacer()
              if host.id == selectedHostID {
                Image(systemName: "checkmark")
                  .accessibilityLabel("Selected")
              }
            }
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .help("Show \(name) in this window")
        }
      }
      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
          .help("Keep the current Mac (Esc)")
      }
    }
    .padding()
    .frame(minWidth: 340, minHeight: 260)
  }
}

extension RemoteClientFeature.State {
  /// The Mac's name: from its `hello`, else from the relay's host list, else a plain word.
  var macName: String {
    if let hostName, !hostName.isEmpty { return hostName }
    if let name = hosts.first(where: { $0.id == selectedHostID })?.name, !name.isEmpty { return name }
    return "Remote Mac"
  }
}

extension RemoteClientStatus {
  /// The title's second line: the path in use, else the connection's state.
  var pathText: String {
    switch self {
    case .online(.lan): "LAN"
    case .online(.relay): "Relay"
    case .connecting: "Connecting…"
    case .choosingHost: "Choose a Mac"
    case .hostOffline: "Offline"
    case .unsupportedHost: "Older Supacode"
    case .failed: "Not connected"
    case .idle: ""
    }
  }
}
