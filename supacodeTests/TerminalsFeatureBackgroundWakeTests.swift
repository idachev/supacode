import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

/// The background wake reuses the generic `.wakeTab`: on a hydrated layout of
/// a worktree that is not selected it provisions the hidden tab's content as
/// `.restored` and changes no selection or focus.
@MainActor
struct TerminalsFeatureBackgroundWakeTests {
  @Test(.dependencies) func wakeTabOnANonSelectedWorktreeProvisionsWithoutSelecting() async {
    let selectedWorktree = Worktree.ID("/tmp/bg-wake/selected")
    let otherWorktree = Worktree.ID("/tmp/bg-wake/other")
    let paneID = PaneID()
    let visibleTab = TabItem(
      id: TabID(),
      title: "One",
      content: ContentSnapshot(id: ContentID(), state: .terminal(TerminalContentState(workingDirectory: nil)))
    )
    let wokenTab = TabItem(
      id: TabID(),
      title: "Two",
      content: ContentSnapshot(id: ContentID(), state: .terminal(TerminalContentState(workingDirectory: nil)))
    )
    let otherLayout = PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [Pane(id: paneID, tabs: [visibleTab, wokenTab], selectedTabID: visibleTab.id)],
      focusedPaneID: paneID
    )
    let selectedPaneID = PaneID()
    let selectedTab = TabItem(
      id: TabID(),
      title: "Selected",
      content: ContentSnapshot(id: ContentID(), state: .terminal(TerminalContentState(workingDirectory: nil)))
    )
    let selectedLayout = PaneLayout(
      tree: SplitTree(view: selectedPaneID),
      panes: [Pane(id: selectedPaneID, tabs: [selectedTab], selectedTabID: selectedTab.id)],
      focusedPaneID: selectedPaneID
    )
    var state = TerminalsFeature.State(layouts: [
      LayoutFeature.State(id: selectedWorktree, layout: selectedLayout),
      LayoutFeature.State(id: otherWorktree, layout: otherLayout),
    ])
    state.selectedWorktreeID = selectedWorktree
    let runtime = ContentRuntime()
    let requests = LockIsolated<[ContentRequest]>([])
    let store = TestStore(initialState: state) {
      TerminalsFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.contentRuntime = runtime
      $0.layoutContentFactory = LayoutContentFactory { request in
        requests.withValue { $0.append(request) }
        return InertTabContent(id: request.contentID, state: request.content)
      }
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
    }
    store.exhaustivity = .off

    await store.send(.layouts(.element(id: otherWorktree, action: .wakeTab(id: wokenTab.id))))
    // The fixture never provisioned the selected worktree's visible tab, so the
    // hibernation reconcile after the action wakes it too: a second request for
    // a different content, not a second provision of the woken tab.
    await store.receive(\.layouts)

    let wokenRequests = requests.value.filter { $0.contentID == wokenTab.content.id }
    #expect(wokenRequests.count == 1)
    #expect(wokenRequests.first?.origin == .restored)
    #expect(wokenRequests.first?.worktreeID == otherWorktree)
    #expect(requests.value.map(\.contentID) == [wokenTab.content.id, selectedTab.content.id])
    #expect(runtime.content(for: wokenTab.content.id) != nil)
    #expect(store.state.selectedWorktreeID == selectedWorktree)
    let layout = store.state.layouts[id: otherWorktree]?.layout
    #expect(layout?.focusedPaneID == paneID)
    #expect(layout?.panes[id: paneID]?.selectedTabID == visibleTab.id)
    let selected = store.state.layouts[id: selectedWorktree]?.layout
    #expect(selected?.focusedPaneID == selectedPaneID)
    #expect(selected?.panes[id: selectedPaneID]?.selectedTabID == selectedTab.id)
    await store.finish()
  }
}
