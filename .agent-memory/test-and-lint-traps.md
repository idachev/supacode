---
name: test-and-lint-traps
description: Read before running make test, one test, swiftlint or swift-format, or when a test fails that the change did not touch.
paths:
  - "Makefile"
  - "Project.swift"
  - "supacodeTests/**"
---

# Test and lint traps

- **Run one test.** The scheme is `supacode-tests` (`-scheme supacode` fails for tests). All
  files sit in `supacodeTests/`, but each suite belongs to one target: `supacodeTests`,
  `supacodeGitTests`, `supacodeFeatureTests` or `supacodeTerminalTests`, and `-only-testing:` needs that target name:
  `DEVELOPER_DIR="$(./scripts/select-developer-dir.sh)" xcodebuild test -workspace supacode.xcworkspace -scheme supacode-tests -destination platform=macOS -derivedDataPath .build/DerivedData -only-testing:supacodeFeatureTests/AppFeatureCommandAckTests`.
  The failure output names the target (`✘ supacodeFeatureTests / ...`).
- **`@Shared` settings leak between tests.** Tests run in one process, and `@Shared` settings
  (for example `deleteScript`) are process-global. A test that changes one sets it back with
  `defer`, or later tests see the changed value. **Why:** this leak came back twice, once as a
  flaky test and once as an upstream merge conflict.
- **Tests that fail only on the owner's machine** came from the Bulgarian keyboard layout
  (shortcut code uses the US letter on purpose, commit `0be38e07`), the personal Ghostty config
  (an empty `TEST_RUNNER_XDG_CONFIG_HOME` isolates it) and a locked
  `$TMPDIR/supacode-theme.conf` (tests point `GhosttyRuntime.themeOverlayDirectory` at a
  private folder). Check these before you debug the code.
- **Known flaky tests.** These fail now and then in the parallel `make test` run and pass on a
  rerun: `RepositoriesFeatureTests.requestArchiveWorktreeShowsConfirmation`,
  `RepositoriesFeatureTests.requestArchiveWorktreesShowsBatchConfirmation`,
  `AppFeatureCommandPaletteTests.archiveWorktreeDispatchesRequest` (it comes with a
  "`@Dependency(\.date)` has no test implementation" issue),
  `RemotePathClassificationTests.resolveRemotePathTimesOutOnAHangingProbe` and
  `WorktreeEnvironmentTests.blockingScriptRunnerEmitsCommandFinishedUnderRealPTYBeforeExecTail`
  (real PTY). Rerun the suite once before you look into them. A failure that repeats is real.
  **Why:** on 2026-10-22 the first four failed in 3 of 6 runs with no related code change; on
  2026-10-26 the PTY test failed once at 13 s in the full run and passed 3 of 3 alone.
- **`check-isolated-deinits.sh` also scans the test bundles** and runs only after every test
  passes, as the last step of `make test`. A main-actor class declared in a test file (even a
  `private` stub such as an `NSView` subclass) needs `nonisolated deinit {}` too, or `make test`
  fails after a green run. **Why:** on 2026-10-25 a fork-only test stub failed it right after
  the upstream merge that added the check.
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
- **swiftlint on a doc-commented declaration.** The config is `strict: true`. To silence a rule on
  a declaration with a `///` comment, use a trailing `// swiftlint:disable:this <rule>` on the
  declaration line; `disable:next` above the doc comment gives `superfluous_disable_command`, and
  between the comment and the declaration gives `orphaned_doc_comment`.
- **swiftlint needs `DEVELOPER_DIR`** (`make lint` does not set it). Without it swiftlint crashes with
  `Loading sourcekitdInProc.framework ... failed`. Run
  `DEVELOPER_DIR="$(./scripts/select-developer-dir.sh)" mise exec -- swiftlint lint --quiet --config .swiftlint.yml <files>`.
- **`make check` rewrites files you did not touch**, because swift-format runs over the whole
  tree. Revert those files before you commit.
- **swift-format needs the project config.** A plain `swift-format lint` prints many old
  warnings (line length, indentation) that are not real. Use
  `mise exec -- swift-format --in-place --configuration ./.swift-format.json <files>`, as `make format` does.
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
- **Exhaustive TestStore tests see new row state.** If a reducer starts to change a new
  `SidebarItemFeature.State` field on `agentSnapshotChanged` or `terminalProjectionChanged`,
  exhaustive tests in `AppFeatureRunScriptTests`, `AppFeatureSettingsChangedTests` and
  `SelectedWorktreeSliceCacheTests` fail with "A state change does not match expectation".
  Add the field to their expected state.
