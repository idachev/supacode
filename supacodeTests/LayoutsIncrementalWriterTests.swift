import Dependencies
import Foundation
import IdentifiedCollections
import Sharing
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct LayoutsIncrementalWriterTests {
  private func makeDefaults() -> UserDefaults {
    // A fresh, isolated in-memory store per test so writes never touch disk.
    .inMemory
  }

  private func makeWriter(_ defaults: UserDefaults) -> LayoutsIncrementalWriter {
    LayoutsIncrementalWriter(store: LayoutsUserDefaultsStore(defaults: defaults))
  }

  private func readFile(_ defaults: UserDefaults) -> LayoutsFile? {
    guard let data = defaults.data(forKey: LayoutsFile.userDefaultsKey) else { return nil }
    return try? JSONDecoder().decode(LayoutsFile.self, from: data)
  }

  @Test func identicalReflushKeepsASingleEntry() async {
    let defaults = makeDefaults()
    let writer = makeWriter(defaults)

    let entry = record("/w1")
    await writer.flush(records: ["w1": .record(entry)])
    // Re-splicing the same record changes nothing; the writer skips the write.
    await writer.flush(records: ["w1": .record(entry)])

    #expect(Set(readFile(defaults)?.worktrees.keys.map { $0 } ?? []) == ["w1"])
  }

  @Test func corruptBlobIsStashedAsideThenRecovers() async {
    let defaults = makeDefaults()
    // A wholly-undecodable blob (genuine corruption, or a newer-schema downgrade).
    let garbage = Data("not json".utf8)
    defaults.set(garbage, forKey: LayoutsFile.userDefaultsKey)
    let writer = makeWriter(defaults)

    await writer.flush(records: ["w1": .record(record("/w1"))])

    // The blob is preserved under a sibling key, and the live store recovers to a
    // fresh value rather than wedging forever.
    #expect(defaults.data(forKey: LayoutsFile.userDefaultsKey + ".corrupt") == garbage)
    #expect(readFile(defaults)?.worktrees["w1"] != nil)
  }

  @Test func emptyChangesIsNoOp() async {
    let defaults = makeDefaults()
    let writer = makeWriter(defaults)

    await writer.flush(records: ["w1": .record(record("/w1"))])
    await writer.flush(records: [:])

    #expect(Set(readFile(defaults)?.worktrees.keys.map { $0 } ?? []) == ["w1"])
  }

  // MARK: - v2 record flushes.

  private func record(_ marker: String) -> LayoutRecord {
    let paneID = PaneID()
    let tabID = TabID()
    return LayoutRecord(
      layout: PaneLayout(
        tree: SplitTree(view: paneID),
        panes: [
          Pane(
            id: paneID,
            tabs: [
              TabItem(
                id: tabID,
                title: marker,
                content: ContentSnapshot(
                  id: ContentID(),
                  state: .terminal(TerminalContentState(workingDirectory: marker))
                )
              )
            ],
            selectedTabID: tabID
          )
        ],
        focusedPaneID: paneID
      )
    )
  }

  @Test func recordFlushesStampAndMergeByWorktree() async {
    let defaults = makeDefaults()
    let writer = makeWriter(defaults)

    await writer.flush(records: ["w1": .record(record("/w1"))])
    await writer.flush(records: ["w2": .record(record("/w2"))])

    let file = readFile(defaults)
    #expect(file?.schemaVersion == LayoutsFile.currentSchemaVersion)
    #expect(Set(file?.worktrees.keys.map { $0 } ?? []) == ["w1", "w2"])
  }

  @Test func recordDeleteRemovesOnlyTargetKey() async {
    let defaults = makeDefaults()
    let writer = makeWriter(defaults)

    await writer.flush(records: ["w1": .record(record("/w1")), "w2": .record(record("/w2"))])
    await writer.flush(records: ["w1": .delete])

    #expect(Set(readFile(defaults)?.worktrees.keys.map { $0 } ?? []) == ["w2"])
  }

  @Test func recordFlushPreservesTheWriteOnceOrigin() async {
    let defaults = makeDefaults()
    let writer = makeWriter(defaults)
    let origin = TerminalLayoutSnapshot(tabs: [], selectedTabIndex: 0)

    // First write lands the migration origin; a later live re-save carries none.
    await writer.flush(records: ["w1": .record(LayoutRecord(layout: record("/w1").layout, origin: origin))])
    await writer.flush(records: ["w1": .record(record("/w1b"))])

    #expect(readFile(defaults)?.worktrees["w1"]?.origin != nil)
  }

  @Test func recordFlushSkipsNewerSchema() async {
    let defaults = makeDefaults()
    let newer = LayoutsFile(schemaVersion: LayoutsFile.currentSchemaVersion + 1, worktrees: [:])
    if let data = try? JSONEncoder().encode(newer) {
      defaults.set(data, forKey: LayoutsFile.userDefaultsKey)
    }
    let writer = makeWriter(defaults)

    await writer.flush(records: ["w1": .record(record("/w1"))])

    #expect(readFile(defaults)?.worktrees.isEmpty == true)
  }

  // MARK: - Split per tab sidecar.

  private func splitPerTabRecord(
    _ fixture: SplitPerTabPersistenceFixture,
    origin: TerminalLayoutSnapshot? = nil
  ) -> LayoutRecord {
    let folded = fixture.layout().foldedForPersistence()
    return LayoutRecord(layout: folded.layout, origin: origin, splitPerTab: folded.sidecar)
  }

  @Test func recordFlushStoresTheSidecarAndReflushIsANoOp() async throws {
    let defaults = makeDefaults()
    let writer = makeWriter(defaults)
    let entry = splitPerTabRecord(SplitPerTabPersistenceFixture())
    #expect(entry.splitPerTab != nil)

    await writer.flush(records: ["w1": .record(entry)])
    let firstBytes = try #require(defaults.data(forKey: LayoutsFile.userDefaultsKey))
    // The decoded record equals the encoded one, so the writer's no-op gate
    // holds and a re-flush leaves the stored bytes alone.
    #expect(readFile(defaults)?.worktrees["w1"] == entry)
    await writer.flush(records: ["w1": .record(entry)])
    #expect(defaults.data(forKey: LayoutsFile.userDefaultsKey) == firstBytes)
  }

  @Test func recordFlushReplacesTheSidecar() async {
    let defaults = makeDefaults()
    let writer = makeWriter(defaults)
    let first = splitPerTabRecord(SplitPerTabPersistenceFixture())
    let second = splitPerTabRecord(SplitPerTabPersistenceFixture())

    await writer.flush(records: ["w1": .record(first)])
    await writer.flush(records: ["w1": .record(second)])

    #expect(readFile(defaults)?.worktrees["w1"]?.splitPerTab == second.splitPerTab)
  }

  @Test func v2RecordFlushRemovesTheSidecarAndKeepsTheOrigin() async {
    let defaults = makeDefaults()
    let writer = makeWriter(defaults)
    let origin = TerminalLayoutSnapshot(tabs: [], selectedTabIndex: 0)

    await writer.flush(records: ["w1": .record(splitPerTabRecord(SplitPerTabPersistenceFixture(), origin: origin))])
    #expect(readFile(defaults)?.worktrees["w1"]?.splitPerTab != nil)
    // A v2-mode write carries no sidecar: it is never inherited from the store,
    // unlike the write-once origin.
    await writer.flush(records: ["w1": .record(record("/w1"))])

    let stored = readFile(defaults)?.worktrees["w1"]
    #expect(stored?.splitPerTab == nil)
    #expect(stored?.origin == origin)
  }
}
