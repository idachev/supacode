import ComposableArchitecture
import Sharing
import SupacodeSettingsShared
import SwiftUI

/// What a pane's strip needs to know about its pane beyond the tabs, as plain values.
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

/// One pane's tab strip in the remote window (ОБ2, ОБ3): a button per tab (title, working
/// shimmer, read-only lock, agent badges, a close button on hover), "+" for a new tab and the pane
/// menu. Every control sends a `RemoteClientFeature` action; the picture changes with the next
/// pushed `list`. The parent sizes it.
struct RemoteTabStripView: View {
  let pane: RemoteLayoutProjection.PaneView
  let chrome: RemotePaneChrome
  let store: StoreOf<RemoteClientFeature>

  @Environment(\.controlActiveState) private var controlActiveState

  var body: some View {
    HStack(spacing: 0) {
      ScrollView(.horizontal) {
        HStack(spacing: TerminalTabBarMetrics.tabSpacing) {
          ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
            RemoteTabButton(
              tab: tab,
              slot: index,
              isSelected: tab.id == pane.selectedTabID,
              isFocusedPane: chrome.isFocused,
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

/// One remote tab. Selecting is the whole tab's button; the close button shows on hover.
private struct RemoteTabButton: View {
  let tab: RemoteClientTab
  let slot: Int
  let isSelected: Bool
  let isFocusedPane: Bool
  let isClosing: Bool
  let onSelect: () -> Void
  let onClose: () -> Void

  @Shared(.settingsFile) private var settingsFile
  @State private var isHovering = false
  @State private var isPressing = false
  @State private var trailingButtonGestureActive = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var title: String { tab.title.isEmpty ? "Terminal" : tab.title }

  /// Only the focused pane's tabs answer Select Tab N.
  private var tooltip: String {
    guard isFocusedPane, slot < AppShortcuts.tabSelection.count else { return title }
    let shortcut = AppShortcuts.tabSelection[slot].effective(from: settingsFile.global.shortcutOverrides)
    return WorktreeGroupStrip.tooltip(title: title, slot: slot, chord: AppShortcut.display(of: shortcut))
  }

  var body: some View {
    HStack(spacing: TerminalTabBarMetrics.contentSpacing) {
      Text(title)
        .appFont(.caption)
        .fontWeight(isSelected ? .semibold : .regular)
        .lineLimit(1)
        .foregroundStyle(TerminalTabBarColors.activeText)
        .shimmer(isActive: tab.working)
        .accessibilityHidden(true)
      Spacer(minLength: 0)
      RemoteAgentBadges(agents: tab.agents, size: 14)
        .fixedSize()
      ZStack(alignment: .trailing) {
        if tab.readOnly {
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
      .accessibilityValue(tab.working ? "Working" : "")
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

/// The strip's trailing controls: exit zoom (zoomed panes only), "+" and the pane menu.
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
      .help("Split, zoom or close this pane")
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

/// The top strip of `splitPerTab`: one button per group (the Mac's top-level tabs), titled by the
/// projection, and "+" for a new top-level tab.
struct RemoteGroupStripView: View {
  let groups: [RemoteLayoutProjection.GroupView]
  let activeGroupID: String?
  let isNewTabBusy: Bool
  let store: StoreOf<RemoteClientFeature>

  @Shared(.settingsFile) private var settingsFile
  @Environment(\.controlActiveState) private var controlActiveState

  var body: some View {
    HStack(spacing: 0) {
      ScrollView(.horizontal) {
        HStack(spacing: TerminalTabBarMetrics.tabSpacing) {
          ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
            RemoteGroupButton(
              title: group.title.isEmpty ? "Terminal" : group.title,
              tooltip: tooltip(group, slot: index),
              isSelected: group.id == activeGroupID
            ) {
              store.send(.groupSelected(group.id))
            }
            if index < groups.count - 1 {
              TerminalTabDivider()
            }
          }
        }
        .frame(height: TerminalTabBarMetrics.barHeight)
      }
      .scrollIndicators(.never)
      Spacer(minLength: 0)
      RemoteStripIconButton(
        title: "New Tab", systemImage: "plus",
        help: AppShortcut.helpText(
          "New Tab", shortcut: AppShortcuts.newTerminalTab.effective(from: settingsFile.global.shortcutOverrides))
      ) {
        store.send(.newTabTapped(paneID: nil))
      }
      .disabled(isNewTabBusy)
      .padding(.trailing, 8)
    }
    .frame(height: TerminalTabBarMetrics.barHeight)
    .saturation(controlActiveState == .inactive ? 0 : 1)
    .clipped()
  }

  private func tooltip(_ group: RemoteLayoutProjection.GroupView, slot: Int) -> String {
    let title = group.title.isEmpty ? "Terminal" : group.title
    guard slot < AppShortcuts.tabSelection.count else { return title }
    let shortcut = AppShortcuts.tabSelection[slot].effective(from: settingsFile.global.shortcutOverrides)
    return WorktreeGroupStrip.tooltip(title: title, slot: slot, chord: AppShortcut.display(of: shortcut))
  }
}

/// One group of the `splitPerTab` strip.
private struct RemoteGroupButton: View {
  let title: String
  let tooltip: String
  let isSelected: Bool
  let action: () -> Void

  @State private var isHovering = false
  @State private var isPressing = false

  var body: some View {
    Text(title)
      .appFont(.caption)
      .fontWeight(isSelected ? .semibold : .regular)
      .lineLimit(1)
      .foregroundStyle(TerminalTabBarColors.activeText)
      .accessibilityHidden(true)
      .padding(.horizontal, TerminalTabBarMetrics.tabHorizontalPadding)
      .frame(
        minWidth: TerminalTabBarMetrics.tabMinWidth,
        maxWidth: TerminalTabBarMetrics.tabMaxWidth,
        minHeight: TerminalTabBarMetrics.tabHeight,
        maxHeight: TerminalTabBarMetrics.tabHeight
      )
      .background {
        Button(action: action) {
          Color.clear.contentShape(.rect)
        }
        .buttonStyle(TerminalPressTrackingButtonStyle(isPressed: $isPressing))
        .accessibilityLabel(title)
        .help(tooltip)
      }
      .opacity(isSelected || isPressing ? 1 : TerminalTabBarMetrics.inactiveContentOpacityIdle)
      .background {
        TerminalTabBackground(isActive: isSelected, isHovering: isHovering, isPressing: isPressing, isDragging: false)
      }
      .overlay(alignment: .top) {
        PaneTabStripe(
          isSelected: isSelected, isHovering: isHovering, isPressing: isPressing, tintColor: nil,
          progressDisplay: nil)
      }
      .contentShape(.rect)
      .onHover { isHovering = $0 }
  }
}
