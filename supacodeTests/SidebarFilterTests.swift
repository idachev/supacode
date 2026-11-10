import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// The sidebar filter's matching rules (ported from Supacode Remote's Android
/// `FuzzyMatch` / `SessionGroups.filter`) and how they shape the filtered
/// sidebar structure.
@MainActor
struct SidebarFilterTests {
  // MARK: - Matcher.

  @Test func emptyOrWhitespaceQueryIsNoFilter() {
    #expect(SidebarFilter(query: "") == nil)
    #expect(SidebarFilter(query: "   \n") == nil)
  }

  @Test func queryIsTrimmedAndLowercased() {
    #expect(SidebarFilter(query: "  LogIn ")?.needle == "login")
  }

  @Test func substringMatchIgnoresCase() throws {
    let filter = try #require(SidebarFilter(query: "LOGIN"))
    #expect(filter.matches("feature-Login-page"))
    #expect(!filter.matches(nil))
    #expect(!filter.matches(""))
  }

  @Test func allowedErrorsGrowWithQueryLength() {
    #expect(SidebarFilter.allowedErrors(forLength: 1) == 0)
    #expect(SidebarFilter.allowedErrors(forLength: 3) == 0)
    #expect(SidebarFilter.allowedErrors(forLength: 4) == 1)
    #expect(SidebarFilter.allowedErrors(forLength: 5) == 1)
    #expect(SidebarFilter.allowedErrors(forLength: 6) == 2)
    #expect(SidebarFilter.allowedErrors(forLength: 20) == 2)
  }

  @Test func shortQueryMatchesOnlyAsSubstring() throws {
    #expect(try #require(SidebarFilter(query: "mai")).matches("main"))
    #expect(!(try #require(SidebarFilter(query: "mxn")).matches("main")))
    #expect(!(try #require(SidebarFilter(query: "abd")).matches("abc")))
  }

  @Test func fourToFiveCharacterQueryToleratesOneError() throws {
    // Missing letter, swapped neighbours, changed letter: one edit each.
    #expect(try #require(SidebarFilter(query: "logn")).matches("feature-login"))
    #expect(try #require(SidebarFilter(query: "mian")).matches("main"))
    #expect(try #require(SidebarFilter(query: "lxgin")).matches("login"))
    #expect(!(try #require(SidebarFilter(query: "lxgn")).matches("login")))
  }

  @Test func sixOrMoreCharacterQueryToleratesTwoErrors() throws {
    #expect(try #require(SidebarFilter(query: "fetaure")).matches("feature"))
    #expect(try #require(SidebarFilter(query: "fxtxure")).matches("feature"))
    #expect(!(try #require(SidebarFilter(query: "fxxxure")).matches("feature")))
  }

  @Test func diacriticsAreNotFolded() throws {
    #expect(!(try #require(SidebarFilter(query: "ete")).matches("été")))
    #expect(try #require(SidebarFilter(query: "ÉTÉ")).matches("été"))
  }

  // MARK: - Fixtures.

  private struct Fixture {
    var state: RepositoriesFeature.State
    let app: Repository
    let other: Repository
    let appMain: Worktree
    let login: Worktree
    let bugfix: Worktree
    let otherMain: Worktree
    let android: Worktree
  }

  private func makeWorktree(_ name: String, in root: URL) -> Worktree {
    let path = root.appending(path: name).path(percentEncoded: false)
    return Worktree(id: WorktreeID(path), name: name, detail: "", workingDirectory: URL(fileURLWithPath: path),
      repositoryRootURL: root)
  }

  private func makeMain(in root: URL) -> Worktree {
    Worktree(
      id: WorktreeID(root.path(percentEncoded: false)), name: "main", detail: "", workingDirectory: root,
      repositoryRootURL: root)
  }

  private func makeFixture() -> Fixture {
    let token = UUID().uuidString
    let appRoot = URL(fileURLWithPath: "/tmp/filter-app-\(token)")
    let otherRoot = URL(fileURLWithPath: "/tmp/filter-other-\(token)")
    let appMain = makeMain(in: appRoot)
    let login = makeWorktree("feature-login", in: appRoot)
    let bugfix = makeWorktree("bugfix", in: appRoot)
    let otherMain = makeMain(in: otherRoot)
    let android = makeWorktree("android-ui", in: otherRoot)
    let app = Repository(
      id: RepositoryID(appRoot.path(percentEncoded: false)), rootURL: appRoot, name: "supacode",
      worktrees: IdentifiedArray(uniqueElements: [appMain, login, bugfix]))
    let other = Repository(
      id: RepositoryID(otherRoot.path(percentEncoded: false)), rootURL: otherRoot, name: "remote",
      worktrees: IdentifiedArray(uniqueElements: [otherMain, android]))
    var state = RepositoriesFeature.State(reconciledRepositories: [app, other])
    state.isInitialLoadComplete = true
    state.applyCacheRecomputes(.all)
    return Fixture(
      state: state, app: app, other: other, appMain: appMain, login: login, bugfix: bugfix,
      otherMain: otherMain, android: android)
  }

  private func rowIDs(_ structure: SidebarStructure) -> [Worktree.ID] {
    structure.sections.flatMap { section -> [Worktree.ID] in
      switch section {
      case .highlight(_, let ids): ids
      case .repository(_, let groups): groups.flatMap(\.rowIDs)
      case .folder(_, let id): [id]
      default: []
      }
    }
  }

  private func filtered(_ state: RepositoriesFeature.State, _ query: String, pinned: Bool = false)
    -> SidebarStructure?
  {
    SidebarFilter(query: query).map {
      state.computeSidebarStructure(groupPinned: pinned, groupActive: false, filter: $0)
    }
  }

  // MARK: - Filtered structure.

  @Test func repositoryNameMatchKeepsAllItsRows() throws {
    let fixture = makeFixture()
    let structure = try #require(filtered(fixture.state, "supacode"))
    #expect(structure.isFiltered)
    #expect(Set(rowIDs(structure)) == [fixture.appMain.id, fixture.login.id, fixture.bugfix.id])
    #expect(structure.sections.compactMap(\.repositoryID) == [fixture.app.id])
  }

  @Test func worktreeMatchKeepsOnlyMatchingRowsAndDropsEmptyRepositories() throws {
    let fixture = makeFixture()
    let structure = try #require(filtered(fixture.state, "login"))
    #expect(rowIDs(structure) == [fixture.login.id])
    #expect(structure.sections.compactMap(\.repositoryID) == [fixture.app.id])
    // Hotkeys walk the visible rows only.
    #expect(structure.hotkeySlots.map(\.id) == [fixture.login.id])
  }

  @Test func worktreeNameMatchesAcrossRepositories() throws {
    let fixture = makeFixture()
    let structure = try #require(filtered(fixture.state, "main"))
    #expect(Set(rowIDs(structure)) == [fixture.appMain.id, fixture.otherMain.id])
  }

  @Test func customTitleIsSearched() throws {
    var fixture = makeFixture()
    fixture.state.sidebarItems[id: fixture.bugfix.id]?.customTitle = "Crash on start"
    let structure = try #require(filtered(fixture.state, "crash"))
    #expect(rowIDs(structure) == [fixture.bugfix.id])
  }

  @Test func nothingMatchingLeavesNoSections() throws {
    let fixture = makeFixture()
    let structure = try #require(filtered(fixture.state, "zzqqxxvv"))
    #expect(structure.isFiltered)
    #expect(structure.sections.isEmpty)
    #expect(structure.hotkeySlots.isEmpty)
  }

  @Test func hiddenPinnedRowDoesNotFallBackIntoItsRepository() throws {
    var fixture = makeFixture()
    fixture.state.$sidebar.withLock { $0.pin(worktree: fixture.login.id, in: fixture.app.id) }
    RepositoriesFeature.syncSidebar(&fixture.state)

    let structure = try #require(filtered(fixture.state, "bugfix", pinned: true))
    #expect(rowIDs(structure) == [fixture.bugfix.id])
    #expect(!structure.sections.contains { if case .highlight = $0 { true } else { false } })

    let pinnedMatch = try #require(filtered(fixture.state, "login", pinned: true))
    #expect(pinnedMatch.sections.first == .highlight(kind: .pinned, rowIDs: [fixture.login.id]))
    // The match lives only in Pinned, so the repository header does not stay empty.
    #expect(pinnedMatch.sections.compactMap(\.repositoryID).isEmpty)
  }

  @Test(.dependencies) func collapsedGroupWithMatchShowsExpandedAndEmptyGroupDisappears() throws {
    var fixture = makeFixture()
    let appGroup = RepositoryGroup(name: "Work", repositoryIDs: [fixture.app.id.rawValue], sidebarCollapsed: true)
    let otherGroup = RepositoryGroup(name: "Phone", repositoryIDs: [fixture.other.id.rawValue])
    fixture.state.$settingsFile.withLock { $0.repositoryGroups = [appGroup, otherGroup] }

    let structure = try #require(filtered(fixture.state, "login"))
    var expandedGroup = appGroup
    expandedGroup.sidebarCollapsed = false
    #expect(structure.sections.first == .repositoryGroup(expandedGroup))
    #expect(rowIDs(structure) == [fixture.login.id])
    #expect(!structure.sections.contains(.repositoryGroup(otherGroup)))
    // The stored collapsed state is untouched.
    #expect(fixture.state.settingsFile.repositoryGroups.first?.sidebarCollapsed == true)
  }

  // MARK: - Reducer.

  @Test func filterQueryArmsSidebarStructureRecompute() {
    #expect(RepositoriesFeature.Action.sidebarFilterQueryChanged("x").cacheInvalidations == .sidebarStructure)
    #expect(RepositoriesFeature.Action.sidebarFilterFocusChanged(true).cacheInvalidations == [])
  }

  @Test func typingFiltersAndClearingRestoresTheFullSidebar() async throws {
    let fixture = makeFixture()
    let full = fixture.state.sidebarStructure
    let store = TestStore(initialState: fixture.state) { RepositoriesFeature() }

    await store.send(.sidebarFilterQueryChanged("login")) {
      $0.sidebarFilterQuery = "login"
      $0.applyPostReduceCacheRecomputes(.sidebarStructure)
    }
    let shown = try #require(store.state.filteredSidebarStructure)
    #expect(rowIDs(shown) == [fixture.login.id])
    #expect(store.state.visibleSidebarStructure == shown)
    // The unfiltered structure (remote snapshot, drag order) is unchanged.
    #expect(store.state.sidebarStructure == full)

    await store.send(.sidebarFilterQueryChanged("   ")) {
      $0.sidebarFilterQuery = "   "
      $0.filteredSidebarStructure = nil
    }
    #expect(store.state.visibleSidebarStructure == full)
  }

  @Test func nextWorktreeWalksOnlyFilteredRows() {
    var fixture = makeFixture()
    fixture.state.sidebarFilterQuery = "bugfix"
    fixture.state.applyCacheRecomputes(.sidebarStructure)
    #expect(fixture.state.worktreeID(byOffset: 1) == fixture.bugfix.id)
    #expect(fixture.state.worktreeID(byOffset: -1) == fixture.bugfix.id)
  }

  @Test func focusRequestSetsFocusState() async {
    let store = TestStore(initialState: makeFixture().state) { RepositoriesFeature() }
    await store.send(.sidebarFilterFocusChanged(true)) {
      $0.isSidebarFilterFocused = true
    }
    await store.send(.sidebarFilterFocusChanged(false)) {
      $0.isSidebarFilterFocused = false
    }
  }
}
