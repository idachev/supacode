import Foundation
import IdentifiedCollections
import SupacodeSettingsShared
import Testing

@testable import supacode

/// `LayoutPersistence.record` for split-per-tab layouts: strip then fold. Lives
/// in the terminal test bundle (the `Layouts*` glob) next to the writer and
/// migrator suites that share `SplitPerTabPersistenceFixture`.
@MainActor
struct LayoutsSplitPerTabPersistenceTests {
  private func v2Layout() -> PaneLayout {
    let paneID = PaneID()
    let tabID = TabID()
    return PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [
            TabItem(
              id: tabID,
              title: "One",
              content: ContentSnapshot(
                id: ContentID(),
                state: .terminal(TerminalContentState(workingDirectory: "/stored"))
              )
            )
          ],
          selectedTabID: tabID
        )
      ],
      focusedPaneID: paneID
    )
  }

  @Test func v2LayoutPersistsWithoutASidecar() {
    let record = LayoutPersistence.record(for: v2Layout(), runtime: ContentRuntime())
    #expect(record.splitPerTab == nil)
  }

  @Test func splitPerTabLayoutPersistsItsV2FoldPlusASidecar() throws {
    let fixture = SplitPerTabPersistenceFixture()
    let live = fixture.layout()
    #expect(live.isConsistent(for: .splitPerTab))

    let record = LayoutPersistence.record(for: live, runtime: ContentRuntime())

    // The base is the consistent v2 projection and holds every content, parked
    // groups included, so the orphan reaper sees all of them.
    #expect(record.layout.activeGroupID == nil)
    #expect(record.layout.isConsistent(for: .tabsPerSplit))
    #expect(Set(record.layout.allContentIDs) == Set(fixture.contentIDs))
    let sidecar = try #require(record.splitPerTab)
    #expect(sidecar == fixture.expectedSidecar)
    let unfolded = try #require(record.layout.unfolding(sidecar))
    #expect(unfolded.isConsistent(for: .splitPerTab))
    #expect(unfolded.groupOrder == live.groupOrder)
  }

  @Test func stripsAScriptGroupBeforeFolding() throws {
    let fixture = SplitPerTabPersistenceFixture()
    let scriptPaneID = PaneID()
    let scriptGroupID = PaneGroupID(rawValue: UUID())
    let scriptTabID = TabID()
    let scriptContentID = ContentID()
    var live = fixture.layout()
    live.panes.append(
      Pane(
        id: scriptPaneID,
        tabs: [
          TabItem(
            id: scriptTabID,
            title: "Setup",
            content: ContentSnapshot(
              id: scriptContentID,
              state: .terminal(
                TerminalContentState(
                  workingDirectory: nil,
                  launch: LaunchOverride(command: "./setup.sh", bypassZmx: true)
                )
              )
            ),
            isLocked: true
          )
        ],
        selectedTabID: scriptTabID
      )
    )
    live.parkedGroups.append(
      PaneGroup(id: scriptGroupID, tree: SplitTree(view: scriptPaneID), focusedPaneID: scriptPaneID)
    )
    live.groupOrder.append(scriptGroupID)
    #expect(live.isConsistent(for: .splitPerTab))

    let record = LayoutPersistence.record(for: live, runtime: ContentRuntime())

    // Stripping runs on the live shape, so the script's group leaves with its
    // pane; folding first would leave the sidecar naming a stripped tab.
    #expect(!record.layout.allContentIDs.contains(scriptContentID))
    #expect(Set(record.layout.allContentIDs) == Set(fixture.contentIDs))
    #expect(record.layout.isConsistent)
    let sidecar = try #require(record.splitPerTab)
    #expect(sidecar == fixture.expectedSidecar)
    #expect(!sidecar.groupOrder.contains(scriptGroupID))
    #expect(record.layout.unfolding(sidecar) != nil)
  }
}

/// A split-per-tab layout shared by the persistence suites: the active group
/// holds one pane; one parked group holds two panes split right, focus on the
/// second. Every pane holds one tab.
nonisolated struct SplitPerTabPersistenceFixture {
  let activeGroupID = PaneGroupID(rawValue: UUID())
  let parkedGroupID = PaneGroupID(rawValue: UUID())
  let activePaneID = PaneID()
  let parkedPaneIDs = [PaneID(), PaneID()]
  let tabIDs = [TabID(), TabID(), TabID()]
  let contentIDs = [ContentID(), ContentID(), ContentID()]

  var parkedTree: SplitTree<PaneID> {
    let tree = SplitTree<PaneID>(view: parkedPaneIDs[0])
    return (try? tree.inserting(view: parkedPaneIDs[1], at: parkedPaneIDs[0], direction: .right)) ?? tree
  }

  func layout() -> PaneLayout {
    let paneIDs = [activePaneID] + parkedPaneIDs
    let panes = paneIDs.indices.map { index in
      Pane(
        id: paneIDs[index],
        tabs: [
          TabItem(
            id: tabIDs[index],
            title: "Tab \(index)",
            content: ContentSnapshot(
              id: contentIDs[index],
              state: .terminal(TerminalContentState(workingDirectory: "/w\(index)"))
            )
          )
        ],
        selectedTabID: tabIDs[index]
      )
    }
    return PaneLayout(
      tree: SplitTree(view: activePaneID),
      panes: IdentifiedArray(uniqueElements: panes),
      focusedPaneID: activePaneID,
      activeGroupID: activeGroupID,
      parkedGroups: [PaneGroup(id: parkedGroupID, tree: parkedTree, focusedPaneID: parkedPaneIDs[1])],
      groupOrder: [activeGroupID, parkedGroupID]
    )
  }

  /// The sidecar the fold of `layout()` must produce.
  var expectedSidecar: SplitPerTabSidecar {
    SplitPerTabSidecar(
      activeGroupID: activeGroupID,
      groupOrder: [activeGroupID, parkedGroupID],
      parkedGroups: [
        SplitPerTabSidecar.ParkedGroup(
          id: parkedGroupID,
          tree: parkedTree,
          focusedPaneID: parkedPaneIDs[1],
          panes: [
            SplitPerTabSidecar.PaneTab(paneID: parkedPaneIDs[0], tabID: tabIDs[1]),
            SplitPerTabSidecar.PaneTab(paneID: parkedPaneIDs[1], tabID: tabIDs[2]),
          ]
        )
      ]
    )
  }
}
