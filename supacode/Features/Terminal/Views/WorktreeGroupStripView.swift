import AppKit
import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Pure lookups behind the split-per-tab group strip, kept out of the view
/// bodies so tests can drive them with plain layouts.
enum WorktreeGroupStrip {
  /// Select Tab N has a chord for the first nine strip positions.
  static let selectableSlotCount = 9

  /// The tab a group shows: its focused pane's selected tab (ОП7), with that
  /// pane. A group has no title of its own.
  static func displayedTab(
    ofGroup id: PaneGroupID,
    in layout: PaneLayout
  ) -> (paneID: PaneID, tab: TabItem)? {
    guard let paneID = layout.focusedPaneID(ofGroup: id),
      let tab = layout.panes[id: paneID]?.selectedTab
    else { return nil }
    return (paneID, tab)
  }

  /// Resolves a tab dropped on the strip to the `moveGroup` it asks for: the
  /// group holding the tab, and its 0-based destination. `index` is the strip
  /// slot the drop landed before (`groupOrder.count` for the strip's end).
  /// Nil when the tab is unknown (another window) or the group would not move.
  static func moveTarget(
    forDraggedTab tabID: TabID,
    droppedAt index: Int,
    in layout: PaneLayout
  ) -> (id: PaneGroupID, toIndex: Int)? {
    guard let pane = layout.pane(containingTab: tabID),
      let groupID = layout.groupID(containingPane: pane.id),
      let sourceIndex = layout.groupOrder.firstIndex(of: groupID)
    else { return nil }
    // The reducer removes the group before inserting it; compensate so a
    // rightward drag still lands before the tab it was dropped on.
    let target = sourceIndex < index ? index - 1 : index
    guard target != sourceIndex else { return nil }
    return (groupID, target)
  }

  /// A group tab's tooltip: its title and, for the first nine, the Select Tab
  /// N item with its chord when one is bound.
  static func tooltip(title: String, slot: Int, chord: String?) -> String {
    guard slot < selectableSlotCount else { return title }
    let item = "Select Tab \(slot + 1)"
    guard let chord else { return "\(title) — \(item)" }
    return "\(title) — \(item) (\(chord))"
  }

  @MainActor
  static func performDrop(
    _ items: [PaneTabDragPayload],
    at index: Int,
    store: StoreOf<LayoutFeature>
  ) -> Bool {
    guard let raw = items.first,
      let target = moveTarget(forDraggedTab: TabID(rawValue: raw.tabID), droppedAt: index, in: store.layout)
    else { return false }
    store.send(.moveGroup(id: target.id, toIndex: target.toIndex))
    return true
  }
}

/// The worktree-level tab strip of split per tab: one tab per group, in strip
/// order, plus the focused pane's accessories. Like `PaneTabStrip`, it has no
/// background so the window tint shows through, and the parent sizes it.
struct WorktreeGroupStripView: View {
  let store: StoreOf<LayoutFeature>
  let runtime: ContentRuntime
  /// Resolves a content id to its observable unseen-notification counter.
  var surfaceState: (UUID) -> WorktreeSurfaceState? = { _ in nil }
  /// Workspace lifecycle work, represented on the active group's tab.
  var isLifecycleBusy = false
  /// Hands the keyboard to the active group's focused terminal after a click,
  /// also when the clicked group already was active.
  var focusSelectedTab: () -> Void = {}

  @Environment(\.controlActiveState) private var controlActiveState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.pixelLength) private var pixelLength
  @State private var containerWidth: CGFloat = 0
  @State private var isAppendDropTargeted = false

  var body: some View {
    // Only the order and the active id: each group tab resolves its own title
    // and chrome, so a chrome tick never invalidates the strip.
    let groupOrder = store.layout.groupOrder
    let activeGroupID = store.layout.activeGroupID
    HStack(spacing: 0) {
      ScrollViewReader { scrollReader in
        ScrollView(.horizontal) {
          tabsRow(groupOrder: groupOrder, activeGroupID: activeGroupID)
        }
        .scrollIndicators(.never)
        .onGeometryChange(for: CGFloat.self) {
          $0.size.width
        } action: {
          containerWidth = $0
        }
        .onAppear {
          if let activeGroupID { scrollReader.scrollTo(activeGroupID, anchor: .center) }
        }
        .onChange(of: activeGroupID) { _, newID in
          guard let newID else { return }
          withAnimation(
            reduceMotion ? nil : .easeInOut(duration: TerminalTabBarMetrics.selectionAnimationDuration)
          ) {
            scrollReader.scrollTo(newID, anchor: .center)
          }
        }
      }
      Spacer(minLength: 0)
      WorktreeGroupStripAccessories(store: store, runtime: runtime)
    }
    .frame(height: TerminalTabBarMetrics.barHeight)
    .saturation(controlActiveState == .inactive ? 0 : 1)
    .clipped()
    .dropDestination(for: PaneTabDragPayload.self) { items, _ in
      // A drop past the last tab moves the group to the end.
      WorktreeGroupStrip.performDrop(items, at: store.layout.groupOrder.count, store: store)
    } isTargeted: {
      isAppendDropTargeted = $0
    }
  }

  private func tabsRow(groupOrder: [PaneGroupID], activeGroupID: PaneGroupID?) -> some View {
    HStack(alignment: .center, spacing: TerminalTabBarMetrics.tabSpacing) {
      ForEach(Array(groupOrder.enumerated()), id: \.element) { index, groupID in
        WorktreeGroupTabView(
          groupID: groupID,
          slot: index,
          isSelected: groupID == activeGroupID,
          fixedWidth: effectiveTabWidth(count: groupOrder.count),
          isLifecycleBusy: isLifecycleBusy,
          store: store,
          runtime: runtime,
          surfaceState: surfaceState,
          focusSelectedTab: focusSelectedTab
        )
        .id(groupID)
        if index < groupOrder.count - 1 {
          TerminalTabDivider()
        }
      }
    }
    .frame(height: TerminalTabBarMetrics.barHeight)
    .animation(
      reduceMotion ? nil : .easeOut(duration: TerminalTabBarMetrics.closeAnimationDuration),
      value: groupOrder
    )
    .overlay(alignment: .trailing) {
      if isAppendDropTargeted {
        PaneTabDropIndicator()
      }
    }
  }

  /// Same fit rule as `PaneTabStrip`: share the width, clamped to the tab
  /// bounds, hairline dividers excluded.
  private func effectiveTabWidth(count: Int) -> CGFloat? {
    guard containerWidth > 0, count > 0 else { return nil }
    let dividers = CGFloat(count - 1) * pixelLength
    let perTab = (containerWidth - dividers) / CGFloat(count)
    return min(TerminalTabBarMetrics.tabMaxWidth, max(TerminalTabBarMetrics.tabMinWidth, perTab))
  }
}

/// The strip's trailing accessories, acting on the focused pane of the active
/// group (new tab, splits, zoom, window mode).
private struct WorktreeGroupStripAccessories: View {
  let store: StoreOf<LayoutFeature>
  let runtime: ContentRuntime

  var body: some View {
    if let paneID = store.layout.focusedPaneID, let pane = store.layout.panes[id: paneID] {
      PaneTabStripAccessories(
        pane: pane,
        isZoomed: isZoomed(paneID),
        isWindowed: store.windowedPaneIDs.contains(paneID),
        store: store,
        runtime: runtime
      )
    }
  }

  private func isZoomed(_ paneID: PaneID) -> Bool {
    guard case .leaf(let leaf) = store.layout.tree.zoomed else { return false }
    return leaf == paneID
  }
}

/// One group in the strip: the title, badges, unseen dot, progress stripe and
/// inline rename of the group's focused content tab. Chrome reads register per
/// content, so an agent or progress tick re-renders only this group tab. There
/// is no close button and no close item (ОП14): a group closes with its last
/// pane.
private struct WorktreeGroupTabView: View {
  let groupID: PaneGroupID
  let slot: Int
  let isSelected: Bool
  let fixedWidth: CGFloat?
  let isLifecycleBusy: Bool
  let store: StoreOf<LayoutFeature>
  let runtime: ContentRuntime
  let surfaceState: (UUID) -> WorktreeSurfaceState?
  let focusSelectedTab: () -> Void

  var body: some View {
    let _ = store.renderEpoch
    if let shown = WorktreeGroupStrip.displayedTab(ofGroup: groupID, in: store.layout) {
      let tab = shown.tab
      WorktreeGroupTabContent(
        groupID: groupID,
        tab: tab,
        slot: slot,
        isSelected: isSelected,
        // A windowed pane's own strip carries the rename field; a second one
        // here would fight it for focus.
        hostsRename: !store.windowedPaneIDs.contains(shown.paneID),
        fixedWidth: fixedWidth,
        isLifecycleBusy: isLifecycleBusy,
        store: store,
        runtime: runtime,
        surfaceState: surfaceState,
        focusSelectedTab: focusSelectedTab
      )
      // One view per displayed tab: when the group's focus moves to another
      // pane mid-rename, the old tab's view disappears and commits to its own
      // tab, never to the newly shown one.
      .id(tab.id)
    }
  }
}

private struct WorktreeGroupTabContent: View {
  let groupID: PaneGroupID
  let tab: TabItem
  let slot: Int
  let isSelected: Bool
  let hostsRename: Bool
  let fixedWidth: CGFloat?
  let isLifecycleBusy: Bool
  let store: StoreOf<LayoutFeature>
  let runtime: ContentRuntime
  let surfaceState: (UUID) -> WorktreeSurfaceState?
  let focusSelectedTab: () -> Void

  @State private var isHovering = false
  @State private var isPressing = false
  @State private var editingTitle = ""
  @State private var initialEditingTitle = ""
  @State private var cancelOnExit = false
  @State private var isDropTargeted = false
  @FocusState private var isFieldFocused: Bool
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var isEditing: Bool {
    hostsRename && store.editingTabID == tab.id
  }

  var body: some View {
    // Content-owned observable chrome, read at this leaf like `PaneTabView`.
    let chrome = runtime.content(for: tab.content.id)?.chrome
    let isDormant = runtime.renderer(for: tab.content.id) == nil
    let progressDisplay = chrome?.progress
    let title = TabTitle.resolved(for: tab, chrome: chrome)
    let isLocked = tab.isLocked
    HStack(spacing: TerminalTabBarMetrics.contentSpacing) {
      PaneTabLabelView(
        tab: tab,
        title: title,
        isSelected: isSelected,
        isDormant: isDormant,
        accessory: chrome?.accessory,
        isShimmering: chrome?.isWorking == true || progressDisplay != nil || (isSelected && isLifecycleBusy)
      )
      .allowsHitTesting(false)
      .accessibilityHidden(true)

      if hasTrailingContent(isLocked: isLocked) {
        ZStack(alignment: .trailing) {
          if isLocked {
            PaneTabLockIndicator(suppress: isShowingHint)
          } else {
            PaneTabNotificationIndicator(
              hasUnseenNotifications: hasUnseenNotifications,
              suppress: isShowingHint
            )
          }
          if isShowingHint, let shortcutHint {
            PaneTabShortcutHintText(hint: shortcutHint)
              .transition(.opacity)
          }
        }
        .frame(minWidth: TerminalTabBarMetrics.closeButtonSize, maxHeight: TerminalTabBarMetrics.closeButtonSize)
        .transition(.opacity)
      }
    }
    .padding(.horizontal, TerminalTabBarMetrics.tabHorizontalPadding)
    .animation(slotAnimation, value: isShowingHint)
    .animation(slotAnimation, value: hasTrailingContent(isLocked: isLocked))
    .opacity(isEditing ? 0 : 1)
    .allowsHitTesting(!isEditing)
    .frame(
      minWidth: TerminalTabBarMetrics.tabMinWidth,
      maxWidth: TerminalTabBarMetrics.tabMaxWidth,
      minHeight: TerminalTabBarMetrics.tabHeight,
      maxHeight: TerminalTabBarMetrics.tabHeight
    )
    .frame(width: fixedWidth)
    // Behind the content so the whole tab selects; the drag handle rides the
    // same layer.
    .background {
      Button {
        store.send(.selectGroup(id: groupID))
        focusSelectedTab()
      } label: {
        Color.clear.contentShape(.rect)
      }
      .buttonStyle(TerminalPressTrackingButtonStyle(isPressed: $isPressing))
      .accessibilityLabel(title)
      .accessibilityValue(progressDisplay?.accessibilityValue ?? "")
      .allowsHitTesting(!isEditing)
      .draggable(PaneTabDragPayload(tabID: tab.id.rawValue)) {
        PaneTabDragPreview(title: title)
      }
    }
    .overlay {
      if isEditing {
        renameField
      }
    }
    .opacity(contentOpacity)
    .saturation(contentSaturation)
    .background {
      TerminalTabBackground(
        isActive: isSelected,
        isHovering: isHovering,
        isPressing: isPressing,
        isDragging: false
      )
    }
    .animation(
      reduceMotion ? nil : .easeInOut(duration: TerminalTabBarMetrics.hoverAnimationDuration),
      value: InteractionKey(isHovering: isHovering, isSelected: isSelected, isPressing: isPressing)
    )
    .padding(.bottom, isSelected ? TerminalTabBarMetrics.activeTabBottomPadding : 0)
    .offset(y: isSelected ? TerminalTabBarMetrics.activeTabOffset : 0)
    .clipShape(.rect(cornerRadius: TerminalTabBarMetrics.tabCornerRadius))
    .overlay(alignment: .top) {
      PaneTabStripe(
        isSelected: isSelected,
        isHovering: isHovering,
        isPressing: isPressing,
        tintColor: tab.tintColor,
        progressDisplay: progressDisplay
      )
    }
    .contentShape(.rect)
    .help(WorktreeGroupStrip.tooltip(title: title, slot: slot, chord: shortcutHint))
    .onHover { hovering in
      isHovering = hovering
    }
    .simultaneousGesture(
      TapGesture(count: 2).onEnded {
        beginRename()
      }
    )
    .onChange(of: isEditing) { _, editing in
      if editing {
        editingTitle = title
        initialEditingTitle = title
        cancelOnExit = false
      } else if cancelOnExit {
        cancelOnExit = false
      } else if editingTitle != initialEditingTitle {
        // An empty commit clears the override on every commit path.
        store.send(.renameTab(id: tab.id, title: editingTitle))
      }
    }
    // The double-click's Button action selects the group first; defer one turn
    // so the field wins the focus.
    .task(id: isEditing) {
      guard isEditing else { return }
      await Task.yield()
      guard !Task.isCancelled else { return }
      isFieldFocused = true
    }
    .onDisappear {
      guard isEditing else { return }
      defer { store.send(.endTabRename) }
      guard !cancelOnExit, editingTitle != initialEditingTitle else { return }
      store.send(.renameTab(id: tab.id, title: editingTitle))
    }
    .zIndex(isSelected ? 2 : 0)
    .overlay(alignment: .leading) {
      // Dropping on a group tab moves the dragged group before it.
      if isDropTargeted {
        PaneTabDropIndicator()
      }
    }
    .dropDestination(for: PaneTabDragPayload.self) { items, _ in
      WorktreeGroupStrip.performDrop(items, at: slot, store: store)
    } isTargeted: {
      isDropTargeted = $0
    }
    .contextMenu {
      if !tab.isLocked {
        Button("Rename Tab") { beginRename() }
      }
    }
  }

  private var renameField: some View {
    TextField("", text: $editingTitle)
      .textFieldStyle(.plain)
      .appFont(.caption)
      .focused($isFieldFocused)
      .foregroundStyle(TerminalTabBarColors.activeText)
      .accessibilityLabel("Rename tab")
      .padding(.horizontal, TerminalTabBarMetrics.tabHorizontalPadding)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .onSubmit { store.send(.endTabRename) }
      .onExitCommand {
        cancelOnExit = true
        store.send(.endTabRename)
      }
      .onChange(of: isFieldFocused) { _, focused in
        guard !focused, isEditing else { return }
        store.send(.endTabRename)
      }
  }

  private struct InteractionKey: Hashable {
    let isHovering: Bool
    let isSelected: Bool
    let isPressing: Bool
  }

  private var contentOpacity: Double {
    if isSelected || isPressing { return 1 }
    return isHovering
      ? TerminalTabBarMetrics.inactiveContentOpacityHover
      : TerminalTabBarMetrics.inactiveContentOpacityIdle
  }

  private var contentSaturation: Double {
    if isSelected || isPressing { return 1 }
    return isHovering
      ? TerminalTabBarMetrics.inactiveContentSaturationHover
      : TerminalTabBarMetrics.inactiveContentSaturationIdle
  }

  /// The Select Tab N chord for this strip slot; ⌘1..9 select groups here.
  private var shortcutHint: String? {
    commandKeyObserver.tabSelectionHint(atSlot: slot)
  }

  /// One strip per worktree, so every group tab hints while ⌘ is held.
  private var isShowingHint: Bool {
    commandKeyObserver.isPressed && shortcutHint != nil
  }

  private func hasTrailingContent(isLocked: Bool) -> Bool {
    isShowingHint || isLocked || hasUnseenNotifications
  }

  private var hasUnseenNotifications: Bool {
    surfaceState(tab.content.id.rawValue)?.hasUnseenNotification == true
  }

  private var slotAnimation: Animation? {
    reduceMotion ? nil : .easeInOut(duration: TerminalTabBarMetrics.fadeAnimationDuration)
  }

  private func beginRename() {
    guard !tab.isLocked else { return }
    store.send(.beginTabRename(id: tab.id))
  }
}
