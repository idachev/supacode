---
name: test-code-traps
description: Read before writing or fixing test code: TestStore, TestClock, @Shared settings, imports, test target routing and fixture files.
paths:
  - "Project.swift"
  - "supacodeTests/**"
---

# Test code traps

- **Clock-driven tests step in small increments.** One `megaYield` followed by one long
  `clock.advance` misses a sleep that registers late and hangs under the parallel `make test`
  load; step the `TestClock` until the condition holds (`step(_:until:within:)` in
  `RemoteAccessRouterTestSupport.swift`). A wait loop in production code uses
  `do { try await Task.sleep(…) } catch { return }`: `try? await Task.sleep` in a `while` spins
  at full speed once the task is cancelled.
- **`@Shared` settings leak between tests.** Tests run in one process, and `@Shared` settings
  (for example `deleteScript`) are process-global. A test that changes one sets it back with
  `defer`, or later tests see the changed value. **Why:** this leak came back twice, once as a
  flaky test and once as an upstream merge conflict.
- **Test files import every module whose members they use.** The test targets build with
  `MemberImportVisibility`: comparing `.ids` to an array literal or reading `.elements` on an
  `OrderedSet` / `IdentifiedArray` fails to compile ("not available due to missing import of
  defining module 'OrderedCollections'") unless the file imports `OrderedCollections`. **Why:** on
  2026-10-23 this stopped `make test` twice after the app itself built.
- **A test helper is visible only inside its own test target.** `Project.swift` routes files by
  glob into four targets (`supacodeGitTests`, `supacodeFeatureTests`, `supacodeTerminalTests`, e.g.
  `supacodeTests/Layouts*.swift` and `LayoutFeature*.swift` go to the terminal one; everything else
  to `supacodeTests`). A fixture in a file of one target cannot be used from another: put it in a
  file that matches its users' glob, or in `sharedTestSupportSources`, which every test target compiles.
- **A `UserDefaults` subclass in a test** must be `nonisolated`. The project sets
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so its overrides otherwise differ in isolation from
  the base and the test target does not compile.
- **Test fixture files load from the source tree.** `testBundle(name:sources:)` in `Project.swift`
  has no `resources:`, so a non-Swift file under `supacodeTests/` is never in a test bundle.
  Load it with `URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/<dir>")`,
  as `AgentHookCommandTests` does (`supacodeTests/Fixtures/AgentHookSessions/`).
- **`#expect` cannot call a mutating method.** `#expect(gate.claim(id))` on a `var` fails to
  compile ("cannot use mutating member on immutable value: '$0' is immutable"): bind the result
  first (`let first = gate.claim(id)`, then `#expect(first)`). **Why:** on 2026-10-26 this stopped
  `make test` after the app built and lint passed.
- **`store.skipReceivedActions()` is strict by default.** After a `receive` that leaves no further
  action in flight it records "There were no received actions to skip.". When an event may or may
  not produce follow-up actions (e.g. presence `session_end` on empty state), use
  `skipReceivedActions(strict: false)`.
- **Non-exhaustive TestStore: `finish()` does not fold received state.** With
  `exhaustivity = .off`, state set by an action an effect sends shows in `store.state` only after
  `receive`, `skipReceivedActions(strict: false)` or the next `send`. Read state after
  `await store.finish(timeout: .seconds(30)); await store.skipReceivedActions(strict: false)`.
  A trailing strict `skipInFlightEffects()` fails ("There were no in-flight effects to skip.") when
  the only effects were quick `.send`s that already landed, so it passes or fails by scheduling; use
  it only when an effect really waits on a TestClock. **Why:** on 2026-10-26 eleven new tests passed
  alone and failed in the parallel `make test`.
- **TerminalsFeature reconciles hibernation after each layout action that can change visibility**
  (`canAffectVisibility`, e.g. `.wakeTab`). A fixture whose selected worktree has an unprovisioned
  visible tab gets an extra `.wakeTab` and an extra content factory request for that tab; count
  requests per tab, not in total.
- **Exhaustive TestStore tests see new row state.** If a reducer starts to change a new
  `SidebarItemFeature.State` field on `agentSnapshotChanged` or `terminalProjectionChanged`,
  exhaustive tests in `AppFeatureRunScriptTests`, `AppFeatureSettingsChangedTests` and
  `SelectedWorktreeSliceCacheTests` fail with "A state change does not match expectation".
  Add the field to their expected state.

A test-built `Store` passed to app code: [[test-store-duplicate-tca]]. Running tests and lint:
[[test-and-lint-traps]].
