import AppKit
import ComposableArchitecture
import Sharing
import SupacodeSettingsShared
import SwiftUI

/// One remote window (ПЗ1, ПЗ2): the Mac's name and path as the title, the Mac's sidebar and the
/// selected worktree's tabs and splits. Its menu actions come from its own store, so they follow the
/// key window.
struct RemoteClientWindowView: View {
  @Bindable var store: StoreOf<RemoteClientFeature>
  let session: RemoteClientSession
  let ghostty: GhosttyRuntime

  var body: some View {
    // `FocusedAction` compares only `isEnabled` and `token`: two remote windows would publish equal
    // values that send to different stores, and the menu would keep the first window's closure.
    let window = ObjectIdentifier(store)
    content
      // Published whatever the window shows, always enabled: otherwise ⌘1…⌘9 and previous / next
      // would reach the main window's tabs while this window is key.
      .focusedSceneAction(\.remoteTabSelectionAction, enabled: true, token: window) { selection in
        switch store.withState(\.projection)?.target(of: selection) {
        case .tab(let paneID, let tabID): store.send(.tabSelected(paneID: paneID, tabID: tabID))
        case .group(let groupID): store.send(.groupSelected(groupID))
        case nil: break
        }
      }
      // R20: the Worktrees menu acts on this window while it is key, never on the main window.
      .focusedSceneValue(
        \.remoteWorktreeMenu,
        RemoteWorktreeMenu(
          canCreateWorktree: store.selectedRepository?.canCreateWorktree == true,
          canRefreshWorktrees: store.list?.canRefreshWorktrees == true,
          perform: FocusedAction(isEnabled: true, token: window) { store.send(.worktreeCommand($0)) }
        )
      )
      // On the window, not the split view: a request that fails as the connection fails (a refused
      // key) shows its alert over the failure screen, not stale after a reconnect. The New Worktree
      // prompt likewise closes (and cancels) only when the user or the reducer closes it. A Close
      // Tab confirmation whose pane is on screen waits for that pane's first flashes (РС5).
      .paneCloseConfirmationAlert(
        $store.scope(state: \.alert, action: \.alert), heldAlertID: store.closeFlash?.alertID
      )
      .sheet(
        isPresented: Binding(
          get: { store.newWorktree != nil },
          set: { if !$0 { store.send(.newWorktreeCancelled) } }
        )
      ) {
        RemoteNewWorktreeSheet(store: store)
      }
      .toolbar(removing: .title)
      .navigationTitle(store.macName)
      .toolbar {
        ToolbarItem(placement: .navigation) {
          RemoteClientTitleButton(
            name: store.macName, detail: store.status.pathText, notice: store.connectionNotice
          ) {
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
          isEveryMacShownElsewhere: store.isEveryMacShownElsewhere,
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
          RemoteClientSplitView(store: store, session: session, ghostty: ghostty)
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
  /// The line under the title while there is no live connection (БН3).
  let notice: String?
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 0) {
        titleLine
        if let notice {
          // A long Mac name makes a long line: it truncates like the name does.
          RemoteBoundedWidthLayout(maxWidth: 420) {
            Text(notice)
              .font(.caption)
              .foregroundStyle(.secondary)
              .truncationMode(.tail)
          }
        }
      }
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 8)
    }
    .buttonStyle(.plain)
    .help("Choose which Mac this window shows")
  }

  private var titleLine: some View {
    HStack(spacing: 6) {
      // A long name truncates instead of pushing the toolbar.
      RemoteBoundedWidthLayout(maxWidth: 280) {
        Text(name)
          .font(.headline)
          .truncationMode(.tail)
      }
      // The notice under the title already says what the state is.
      if notice == nil, !detail.isEmpty {
        Text("·")
          .foregroundStyle(.secondary)
        Text(detail)
          .foregroundStyle(.secondary)
      }
      Image(systemName: "chevron.down")
        .imageScale(.small)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
  }
}

/// Lays out its one child at its ideal width, but at most `maxWidth`, so a long one-line text
/// truncates there even inside a `fixedSize()` parent. A flexible frame would not: given no width,
/// it lets the text keep its full ideal width.
private struct RemoteBoundedWidthLayout: Layout {
  let maxWidth: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let child = subviews.first else { return .zero }
    let limit = min(proposal.width ?? maxWidth, maxWidth)
    let width = min(child.sizeThatFits(.unspecified).width, limit)
    return child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
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

/// The Mac's sidebar and the selected worktree's layout, with the window's terminal menu actions.
private struct RemoteClientSplitView: View {
  @Bindable var store: StoreOf<RemoteClientFeature>
  let session: RemoteClientSession
  let ghostty: GhosttyRuntime

  @Shared(.settingsFile) private var settingsFile
  @FocusState private var isFilterFocused: Bool

  var body: some View {
    let filterShortcut = AppShortcuts.filterSidebar.effective(from: settingsFile.global.shortcutOverrides)
    NavigationSplitView {
      RemoteSidebarView(
        store: store, isFilterFocused: $isFilterFocused, filterShortcut: filterShortcut,
        focusTerminal: focusTerminal
      )
      .navigationSplitViewColumnWidth(min: 220, ideal: 260)
    } detail: {
      RemoteLayoutView(store: store, session: session, ghostty: ghostty, macName: store.macName)
    }
    .modifier(RemoteClientMenuActions(store: store, focusFilter: { isFilterFocused = true }))
    .onAppear {
      // A click into another pane's terminal focuses that pane, as on the Mac. Weak: the store's
      // session client holds the session, so a strong store here would keep both alive after close.
      session.onSurfaceFocused = { [weak store] contentID in
        guard let store, let projection = store.withState(\.projection),
          let paneID = projection.paneID(showing: contentID),
          paneID != projection.focusedPaneID
        else { return }
        store.send(.paneFocused(paneID))
      }
    }
  }

  /// Hands the keyboard to the focused pane's terminal.
  private func focusTerminal() {
    guard let contentID = store.projection?.focusedTab?.contentId,
      let surface = session.attachedContent(contentID)?.renderer as? GhosttySurfaceView
    else { return }
    surface.requestFocus()
  }
}

/// The terminal menu's actions while the remote window is key (ПЗ4): each sends the matching
/// `RemoteClientFeature` action. Keys this window cannot serve stay unpublished, so the menu
/// greys them out instead of acting on the main window.
private struct RemoteClientMenuActions: ViewModifier {
  let store: StoreOf<RemoteClientFeature>
  let focusFilter: () -> Void

  /// The window (its store) too: two remote windows may show the same worktree ids.
  private struct Token: Hashable {
    let window: ObjectIdentifier
    let worktreeID: String?
    let paneID: String?
    let tabID: String?
  }

  func body(content: Content) -> some View {
    let projection = store.projection
    let worktreeID = store.selectedWorktreeID
    let paneID = projection?.focusedPaneID
    let tab = projection?.focusedTab
    let canEditPanes = store.selectedWorktree?.layout != nil
    let isSplit = projection?.isActiveGroupSplit ?? false
    let token = Token(window: ObjectIdentifier(store), worktreeID: worktreeID, paneID: paneID, tabID: tab?.id)
    content
      .focusedSceneAction(\.newTerminalAction, enabled: worktreeID != nil, token: token) {
        store.send(.newTabTapped(paneID: paneID))
      }
      .focusedSceneAction(\.closeTabAction, enabled: tab != nil, token: token) {
        guard let tab else { return }
        store.send(.closeTabTapped(tabID: tab.id))
      }
      .focusedSceneAction(\.splitTerminalAction, enabled: canEditPanes && paneID != nil, token: token) { direction in
        guard let paneID else { return }
        store.send(.splitTapped(paneID: paneID, direction: direction.remoteSplitDirection))
      }
      .focusedSceneAction(\.focusSplitAction, enabled: isSplit && paneID != nil, token: token) { direction in
        store.send(.focusSplitTapped(direction))
      }
      .focusedSceneAction(\.toggleSplitZoomAction, enabled: isSplit && paneID != nil, token: token) {
        guard let paneID else { return }
        store.send(.zoomToggled(paneID: paneID))
      }
      .focusedSceneAction(\.filterSidebarAction, enabled: true, token: ObjectIdentifier(store), perform: focusFilter)
  }
}

/// The branch-name prompt of New Worktree… (СЛ5).
private struct RemoteNewWorktreeSheet: View {
  let store: StoreOf<RemoteClientFeature>

  var body: some View {
    let repositoryID = store.newWorktree?.repositoryID ?? ""
    let repositoryName = store.list?.repos.first { $0.id == repositoryID }?.name ?? "the repository"
    let name = store.newWorktree?.name ?? ""
    let isBusy = store.busyRequests.contains(RemoteClientFeature.RequestKey.make("worktree.new", repositoryID))
    let canCreate = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isBusy
    VStack(alignment: .leading, spacing: 12) {
      Text("New Worktree in \(repositoryName)")
        .font(.headline)
      Text("The Mac creates the worktree and its branch.")
        .foregroundStyle(.secondary)
      TextField(
        "Branch name",
        text: Binding(get: { name }, set: { store.send(.newWorktreeNameChanged($0)) }),
        prompt: Text("Branch name")
      )
      .monospaced()
      .onSubmit {
        if canCreate { store.send(.newWorktreeConfirmed) }
      }
      HStack {
        Spacer()
        Button("Cancel") { store.send(.newWorktreeCancelled) }
          .keyboardShortcut(.cancelAction)
          .help("Close without creating a worktree (Esc)")
        Button("Create") { store.send(.newWorktreeConfirmed) }
          .keyboardShortcut(.defaultAction)
          .disabled(!canCreate)
          .help("Create the worktree on the Mac (Return)")
      }
    }
    .padding()
    .frame(minWidth: 360)
  }
}

/// The Mac picker: every Mac on the relay but this one and those other remote windows show, with an
/// online dot.
private struct RemoteHostPickerView: View {
  let hosts: [RemoteClientHostInfo]
  /// No row left because other remote windows show every other Mac.
  let isEveryMacShownElsewhere: Bool
  let selectedHostID: String?
  let onPick: (String) -> Void
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Choose a Mac")
        .font(.headline)
      if hosts.isEmpty {
        Text(
          isEveryMacShownElsewhere
            ? "Every other Mac on this relay is already open in a window."
            : "No other Mac shares its Supacode on this relay.")
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
  /// The Mac's name from its `hello`, else from the relay's host list; nil before either is known.
  var knownMacName: String? {
    if let hostName, !hostName.isEmpty { return hostName }
    if let name = hosts.first(where: { $0.id == selectedHostID })?.name, !name.isEmpty { return name }
    return nil
  }

  /// The picker has no row only because other remote windows show every other Mac.
  var isEveryMacShownElsewhere: Bool {
    pickableHosts.isEmpty && !RemoteHostChoice.pickable(hosts, ownHostID: ownHostID).isEmpty
  }

  /// The Mac's name, else a plain word.
  var macName: String {
    knownMacName ?? "Remote Mac"
  }

  /// The window shows a Mac's list and the link to it is not online: the sidebar dims.
  var isLinkDown: Bool {
    list != nil && !status.isOnline
  }

  /// The line under the title and over the dimmed sidebar (БН3): nil while online, and before the
  /// window has a list (its waiting and failure screens already say it).
  var connectionNotice: String? {
    guard isLinkDown else { return nil }
    return RemoteConnectionBanner.text(
      status: status, isAttached: false, wasAttached: hasBeenOnline, hostName: knownMacName)
  }
}

extension RemoteLayoutProjection {
  /// The focused pane's selected tab: what Close Tab closes and the keyboard types into.
  var focusedTab: RemoteClientTab? {
    guard let pane = focusedPaneID.flatMap({ panes[$0] }) else { return nil }
    return pane.tabs.first { $0.id == pane.selectedTabID }
  }
}

extension RemoteClientStatus {
  var isOnline: Bool {
    if case .online = self { true } else { false }
  }

  /// The text next to the Mac's name in the title ("Office Mac · LAN"): the path in use, else the
  /// connection's state. The line under the name is the notice (`connectionNotice`).
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

extension TerminalSplitMenuDirection {
  /// The protocol's `pane.split` is two-way: left and right split side by side, up and down
  /// one above the other; the Mac places the new pane.
  fileprivate var remoteSplitDirection: SplitDirection {
    switch self {
    case .right, .left: .horizontal
    case .down, .up: .vertical
    }
  }
}
