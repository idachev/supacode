import ComposableArchitecture
import Sharing
import SupacodeSettingsShared
import SwiftUI

/// What a strip needs to know about a pane beyond its tabs, as plain values.
struct RemotePaneChrome: Equatable {
  let isFocused: Bool
  let isZoomed: Bool
  /// The group's tree has more than one pane: zoom means something.
  let canZoom: Bool
  /// The worktree sent a `layout`, so its pane ids are real and can be split or closed.
  let canEditPanes: Bool
  let isNewTabBusy: Bool
  let isSplitBusy: Bool
  let isCloseBusy: Bool
  /// Tab ids whose `tab.close` is in flight.
  let closingTabIDs: Set<String>
}

/// One pane's tab strip in `tabsPerSplit` (ОБ2, ОБ3): a button per tab (title, working shimmer,
/// read-only lock, agent badges, a close button on hover), "+" for a new tab and the pane menu.
/// Every control sends a `RemoteClientFeature` action; the picture changes with the next pushed
/// `list`. The parent sizes it.
struct RemoteTabStripView: View {
  let pane: RemoteLayoutProjection.PaneView
  let chrome: RemotePaneChrome
  let store: StoreOf<RemoteClientFeature>

  @Shared(.settingsFile) private var settingsFile
  @Environment(\.controlActiveState) private var controlActiveState

  var body: some View {
    let overrides = settingsFile.global.shortcutOverrides
    HStack(spacing: 0) {
      ScrollView(.horizontal) {
        HStack(spacing: TerminalTabBarMetrics.tabSpacing) {
          ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
            let title = RemoteStripTab.title(tab.title)
            RemoteTabButton(
              title: title,
              tab: tab,
              // Select Tab N picks the focused pane's tabs.
              tooltip: RemoteStripTab.tooltip(
                title: title, slot: index, selectsBySlot: chrome.isFocused, overrides: overrides),
              isSelected: tab.id == pane.selectedTabID,
              isClosing: chrome.closingTabIDs.contains(tab.id),
              onSelect: { store.send(.tabSelected(paneID: pane.id, tabID: tab.id)) },
              onClose: { store.send(.closeTabTapped(tabID: tab.id)) }
            )
            if index < pane.tabs.count - 1 {
              TerminalTabDivider()
            }
          }
        }
        .frame(height: TerminalTabBarMetrics.barHeight)
      }
      .scrollIndicators(.never)
      Spacer(minLength: 0)
      RemotePaneAccessories(paneID: pane.id, chrome: chrome, store: store)
    }
    .frame(height: TerminalTabBarMetrics.barHeight)
    .saturation(controlActiveState == .inactive ? 0 : 1)
    .clipped()
  }
}

/// The only strip of `splitPerTab`, as the local `WorktreeGroupStripView`: one tab per group (the
/// Mac's top-level tabs), each showing its focused pane's selected tab with its badges and a close
/// button on hover, then the focused pane's "+" and pane menu. Panes have no strip of their own.
struct RemoteGroupStripView: View {
  let projection: RemoteLayoutProjection
  /// The active group's focused pane, which "+" and the pane menu act on.
  let focusedPaneID: String?
  let focusedChrome: RemotePaneChrome?
  /// Tab ids whose `tab.close` is in flight.
  let closingTabIDs: Set<String>
  let store: StoreOf<RemoteClientFeature>

  @Shared(.settingsFile) private var settingsFile
  @Environment(\.controlActiveState) private var controlActiveState

  var body: some View {
    let overrides = settingsFile.global.shortcutOverrides
    HStack(spacing: 0) {
      ScrollView(.horizontal) {
        HStack(spacing: TerminalTabBarMetrics.tabSpacing) {
          ForEach(Array(projection.groups.enumerated()), id: \.element.id) { index, group in
            let tab = projection.displayedTab(of: group)
            let title = RemoteStripTab.title(group.title)
            RemoteTabButton(
              title: title,
              tab: tab,
              tooltip: RemoteStripTab.tooltip(title: title, slot: index, selectsBySlot: true, overrides: overrides),
              isSelected: group.id == projection.activeGroupID,
              isClosing: tab.map { closingTabIDs.contains($0.id) } ?? true,
              onSelect: { store.send(.groupSelected(group.id)) },
              onClose: {
                guard let tab else { return }
                store.send(.closeTabTapped(tabID: tab.id))
              }
            )
            if index < projection.groups.count - 1 {
              TerminalTabDivider()
            }
          }
        }
        .frame(height: TerminalTabBarMetrics.barHeight)
      }
      .scrollIndicators(.never)
      Spacer(minLength: 0)
      if let focusedPaneID, let focusedChrome {
        RemotePaneAccessories(paneID: focusedPaneID, chrome: focusedChrome, store: store)
      }
    }
    .frame(height: TerminalTabBarMetrics.barHeight)
    .saturation(controlActiveState == .inactive ? 0 : 1)
    .clipped()
  }
}

/// A strip tab's title and tooltip, shared by both strips.
enum RemoteStripTab {
  static func title(_ title: String) -> String {
    title.isEmpty ? "Terminal" : title
  }

  /// The title and, for the first nine tabs Select Tab N picks, that item and its chord.
  static func tooltip(
    title: String, slot: Int, selectsBySlot: Bool, overrides: [AppShortcutID: AppShortcutOverride]
  ) -> String {
    guard selectsBySlot, slot < AppShortcuts.tabSelection.count else { return title }
    let shortcut = AppShortcuts.tabSelection[slot].effective(from: overrides)
    return WorktreeGroupStrip.tooltip(title: title, slot: slot, chord: AppShortcut.display(of: shortcut))
  }
}

/// One strip tab. Selecting is the whole tab's button; the close button shows on hover.
private struct RemoteTabButton: View {
  let title: String
  /// The tab whose badges, working shimmer and lock show; nil draws the title only.
  let tab: RemoteClientTab?
  let tooltip: String
  let isSelected: Bool
  let isClosing: Bool
  let onSelect: () -> Void
  let onClose: () -> Void

  @State private var isHovering = false
  @State private var isPressing = false
  @State private var trailingButtonGestureActive = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let isWorking = tab?.working == true
    HStack(spacing: TerminalTabBarMetrics.contentSpacing) {
      Text(title)
        .appFont(.caption)
        .fontWeight(isSelected ? .semibold : .regular)
        .lineLimit(1)
        .foregroundStyle(TerminalTabBarColors.activeText)
        .shimmer(isActive: isWorking)
        // Clicks on the label reach the select button behind it, as on a local tab.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      Spacer(minLength: 0)
      RemoteAgentBadges(agents: tab?.agents ?? [], size: 14)
        .fixedSize()
        .allowsHitTesting(false)
      // The lock ignores clicks itself; the close button above it stays hit-testable.
      ZStack(alignment: .trailing) {
        if tab?.readOnly == true {
          PaneTabLockIndicator(suppress: isHovering)
        }
        TerminalTabTrailingButton(
          title: "Close Tab",
          systemImage: "xmark",
          shortcut: AppShortcuts.closeTab,
          isVisible: isHovering && !isClosing,
          action: onClose,
          gestureActive: $trailingButtonGestureActive
        )
      }
      .frame(width: TerminalTabBarMetrics.closeButtonSize, height: TerminalTabBarMetrics.closeButtonSize)
    }
    .padding(.horizontal, TerminalTabBarMetrics.tabHorizontalPadding)
    .frame(
      minWidth: TerminalTabBarMetrics.tabMinWidth,
      maxWidth: TerminalTabBarMetrics.tabMaxWidth,
      minHeight: TerminalTabBarMetrics.tabHeight,
      maxHeight: TerminalTabBarMetrics.tabHeight
    )
    // Behind the content so the whole tab selects; the close button hit-tests above it.
    .background {
      Button(action: onSelect) {
        Color.clear.contentShape(.rect)
      }
      .buttonStyle(TerminalPressTrackingButtonStyle(isPressed: $isPressing))
      .accessibilityLabel(title)
      .accessibilityValue(isWorking ? "Working" : "")
      .help(tooltip)
    }
    .opacity(isSelected || isPressing ? 1 : TerminalTabBarMetrics.inactiveContentOpacityIdle)
    .background {
      TerminalTabBackground(isActive: isSelected, isHovering: isHovering, isPressing: isPressing, isDragging: false)
    }
    .padding(.bottom, isSelected ? TerminalTabBarMetrics.activeTabBottomPadding : 0)
    .offset(y: isSelected ? TerminalTabBarMetrics.activeTabOffset : 0)
    .overlay(alignment: .top) {
      PaneTabStripe(
        isSelected: isSelected, isHovering: isHovering, isPressing: isPressing, tintColor: nil, progressDisplay: nil)
    }
    .contentShape(.rect)
    .onHover { isHovering = $0 }
    .animation(
      reduceMotion ? nil : .easeInOut(duration: TerminalTabBarMetrics.hoverAnimationDuration), value: isHovering
    )
    .zIndex(isSelected ? 2 : 0)
  }
}

/// A strip's trailing controls: exit zoom (zoomed panes only), "+" and the pane menu.
private struct RemotePaneAccessories: View {
  let paneID: String
  let chrome: RemotePaneChrome
  let store: StoreOf<RemoteClientFeature>

  @Shared(.settingsFile) private var settingsFile

  private func help(_ title: String, _ shortcut: AppShortcut?) -> String {
    AppShortcut.helpText(title, shortcut: shortcut?.effective(from: settingsFile.global.shortcutOverrides))
  }

  var body: some View {
    HStack(spacing: 0) {
      if chrome.isZoomed {
        RemoteStripIconButton(
          title: "Exit Split Zoom", systemImage: "arrow.down.right.and.arrow.up.left",
          help: help("Exit Split Zoom", AppShortcuts.toggleSplitZoom), isProminent: true
        ) {
          store.send(.zoomToggled(paneID: paneID))
        }
      }
      RemoteStripIconButton(
        title: "New Tab", systemImage: "plus", help: help("New Tab", AppShortcuts.newTerminalTab)
      ) {
        store.send(.newTabTapped(paneID: paneID))
      }
      .disabled(chrome.isNewTabBusy)
      Menu {
        Button("Split Right", systemImage: TerminalSplitMenuDirection.right.systemImage) {
          store.send(.splitTapped(paneID: paneID, direction: .horizontal))
        }
        .help(help("Split Right", AppShortcuts.splitRight))
        .disabled(!chrome.canEditPanes || chrome.isSplitBusy)
        Button("Split Down", systemImage: TerminalSplitMenuDirection.down.systemImage) {
          store.send(.splitTapped(paneID: paneID, direction: .vertical))
        }
        .help(help("Split Down", AppShortcuts.splitDown))
        .disabled(!chrome.canEditPanes || chrome.isSplitBusy)
        Divider()
        Button("Toggle Split Zoom", systemImage: "arrow.up.left.and.arrow.down.right") {
          store.send(.zoomToggled(paneID: paneID))
        }
        .help(help("Toggle Split Zoom", AppShortcuts.toggleSplitZoom))
        .disabled(!chrome.canZoom)
        Divider()
        Button("Close Pane…", systemImage: "xmark.rectangle", role: .destructive) {
          store.send(.closePaneTapped(paneID: paneID))
        }
        .help("Close this pane and every tab in it on the Mac")
        .disabled(!chrome.canEditPanes || chrome.isCloseBusy)
      } label: {
        Image(systemName: "chevron.down")
          .imageScale(.small)
          .font(.caption2)
          .frame(minWidth: 16, minHeight: TerminalTabBarMetrics.barHeight)
          .contentShape(.rect)
          .accessibilityLabel("Pane Actions")
      }
      .menuStyle(.secondaryToolbar)
      .help("Split, zoom or close the focused pane")
    }
    .frame(height: TerminalTabBarMetrics.barHeight)
    .padding(.trailing, 8)
  }
}

/// An icon-only strip button with its tooltip.
struct RemoteStripIconButton: View {
  let title: String
  let systemImage: String
  let help: String
  var isProminent = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .labelStyle(.iconOnly)
        .frame(minWidth: TerminalTabBarMetrics.barHeight, minHeight: TerminalTabBarMetrics.barHeight)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .foregroundStyle(isProminent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
    .help(help)
  }
}
