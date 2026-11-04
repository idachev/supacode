import Foundation
import IdentifiedCollections
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct RemoteAccessSnapshotSourceTests {
  private func tab(_ title: String, customTitle: String? = nil) -> TabItem {
    TabItem(
      id: TabID(),
      title: title,
      customTitle: customTitle,
      content: ContentSnapshot(id: ContentID(), state: .terminal(TerminalContentState(workingDirectory: nil)))
    )
  }

  private func layout(_ panes: [[TabItem]], focused: Int = 0) -> PaneLayout {
    let built = panes.map { Pane(id: PaneID(), tabs: IdentifiedArray(uniqueElements: $0)) }
    let tree = built.dropFirst().reduce(SplitTree(view: built[0].id)) { tree, pane in
      (try? tree.inserting(view: pane.id, at: built[0].id, direction: .right)) ?? tree
    }
    return PaneLayout(tree: tree, panes: IdentifiedArray(uniqueElements: built), focusedPaneID: built[focused].id)
  }

  @Test func tabsCarryChromeAgentsWorkingAndTitles() {
    let agentTab = tab("zsh")
    let plainTab = tab("build", customTitle: "Build")
    let otherPaneTab = tab("logs")
    let layout = layout([[agentTab, plainTab], [otherPaneTab]])
    let runtime = ContentRuntime()
    let content = ChromeTabContent(id: agentTab.content.id)
    content.terminalChrome.agents = [AgentPresenceFeature.AgentInstance(agent: .claude, activity: .awaitingInput)]
    content.terminalChrome.isWorking = true
    content.terminalChrome.reportedTitle = "claude · fix tests"
    #expect(runtime.provision(content, at: .fallback))

    let tabs = RemoteSnapshotSource.tabs(in: layout, runtime: runtime)

    #expect(tabs.map(\.title) == ["claude · fix tests", "Build", "logs"])
    #expect(tabs.map(\.contentId) == [agentTab, plainTab, otherPaneTab].map { $0.content.id.rawValue.uuidString })
    #expect(tabs[0].agents == [RemoteAgent(agent: "claude", activity: "awaitingInput")])
    #expect(tabs.map(\.working) == [true, false, false])
    // Not registered yet (never started): no agents, not working.
    #expect(tabs[1].agents.isEmpty)
  }

  @Test func focusedTabIsTheSelectedTabOfTheFocusedPane() {
    let first = tab("a")
    let second = tab("b")
    var layout = layout([[first], [second]], focused: 1)
    layout.panes[id: layout.panes[1].id]?.selectedTabID = second.id
    let tabs = RemoteSnapshotSource.tabs(in: layout, runtime: ContentRuntime())
    #expect(tabs.map(\.focused) == [false, true])
  }
}
