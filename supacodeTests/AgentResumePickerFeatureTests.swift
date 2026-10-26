import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Sharing
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct AgentResumePickerFeatureTests {
  // MARK: - Picker reducer.

  @Test func toggleRowFlipsTheSelection() async {
    let rows = Self.rows(count: 2)
    let store = TestStore(initialState: Self.state(rows: rows)) {
      AgentResumePickerFeature()
    }

    await store.send(.toggleRow(rows[1].id)) {
      $0.selected = [rows[0].id]
    }
    await store.send(.toggleRow(rows[1].id)) {
      $0.selected = [rows[0].id, rows[1].id]
    }
  }

  @Test func resumeSelectedSendsTheTickedIDsInRowOrderAndDismisses() async {
    let rows = Self.rows(count: 3)
    let dismissed = LockIsolated(false)
    let store = TestStore(initialState: Self.state(rows: rows)) {
      AgentResumePickerFeature()
    } withDependencies: {
      $0.dismiss = DismissEffect { dismissed.setValue(true) }
    }

    await store.send(.toggleRow(rows[1].id)) {
      $0.selected = [rows[0].id, rows[2].id]
    }
    await store.send(.resumeSelectedTapped)
    await store.receive(.delegate(.resumeRequested([rows[0].id, rows[2].id])))
    await store.finish()
    #expect(dismissed.value)
  }

  @Test func notNowDismissesWithoutADelegate() async {
    let dismissed = LockIsolated(false)
    let store = TestStore(initialState: Self.state(rows: Self.rows(count: 1))) {
      AgentResumePickerFeature()
    } withDependencies: {
      $0.dismiss = DismissEffect { dismissed.setValue(true) }
    }

    await store.send(.notNowTapped)
    await store.finish()
    #expect(dismissed.value)
  }

  // MARK: - Command palette item.

  @Test func paletteListsTheItemOnlyWhileAResumeIsPending() {
    let without = CommandPaletteFeature.items(in: .commands, from: RepositoriesFeature.State())
    let with = CommandPaletteFeature.items(
      in: .commands,
      from: RepositoriesFeature.State(),
      hasPendingAgentResumes: true
    )

    #expect(!without.contains { $0.kind == .resumeAgentSessions })
    let item = with.first { $0.kind == .resumeAgentSessions }
    #expect(item?.id == "global.resume-agent-sessions")
    #expect(item?.title == "Resume Agent Sessions")
    #expect(item?.isGlobal == true)
    #expect(item?.isRootAction == true)
    #expect(item?.appShortcut?.id == .resumeAgentSessions)
  }

  /// `isRootAction` is true as for "View Archived Worktrees", so the item is
  /// found by typing, exactly like the other root actions.
  @Test func paletteItemIsFoundByTyping() {
    let items = CommandPaletteFeature.items(
      in: .commands,
      from: RepositoriesFeature.State(),
      hasPendingAgentResumes: true
    )

    let result = CommandPaletteFeature.filterItems(items: items, query: "resume agent")

    #expect(result.first?.kind == .resumeAgentSessions)
  }

  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func activatingThePaletteItemSendsTheDelegate() async {
    let now = Date(timeIntervalSince1970: 1_234_567)
    let item = CommandPaletteItem(
      id: "global.resume-agent-sessions",
      title: "Resume Agent Sessions",
      subtitle: nil,
      kind: .resumeAgentSessions
    )
    var state = CommandPaletteFeature.State()
    state.isPresented = true
    let store = TestStore(initialState: state) {
      CommandPaletteFeature()
    }
    store.dependencies.date = .constant(now)

    await store.send(.activateItem(item)) {
      $0.isPresented = false
      $0.query = ""
      $0.selectedIndex = nil
      $0.recencyByItemID[item.id] = now.timeIntervalSince1970
    }
    await store.receive(.delegate(.resumeAgentSessions))
  }

  @Test func shortcutIsControlCommandR() {
    #expect(AppShortcuts.all.contains { $0.id == .resumeAgentSessions })
    #expect(AppShortcuts.resumeAgentSessions.displayName == "Resume Agent Sessions")
  }

  // MARK: - Support.

  private static func rows(count: Int) -> IdentifiedArrayOf<PendingAgentResume> {
    IdentifiedArray(
      uniqueElements: (0..<count).map { index in
        PendingAgentResume(
          id: ContentID(),
          worktreeID: WorktreeID("/tmp/picker-repo/wt-\(index)"),
          tabID: TabID(),
          repositoryName: "Repo",
          worktreeName: "wt-\(index)",
          tabTitle: "tab-\(index)",
          agent: "claude",
          sessionID: UUID().uuidString.lowercased()
        )
      }
    )
  }

  private static func state(rows: IdentifiedArrayOf<PendingAgentResume>) -> AgentResumePickerFeature.State {
    AgentResumePickerFeature.State(id: UUID(0), rows: rows, selected: Set(rows.ids))
  }
}
