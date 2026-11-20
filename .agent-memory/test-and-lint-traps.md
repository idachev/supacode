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
  A single Swift Testing test needs its `()`: `-only-testing:supacodeFeatureTests/RepositoriesFeatureTests/requestArchiveWorktreeShowsConfirmation()`.
  Without `()` no test runs and xcodebuild still prints `** TEST SUCCEEDED **`; a suite name
  alone needs no `()`. **Why:** on 2026-11-10 three reruns "passed" with 0 tests executed.
  A NEW test file is in no target until `mise exec -- tuist generate --no-open --cache-profile development`
  runs; before that `-only-testing:` on it also runs 0 tests and prints `TEST SUCCEEDED`.
- **zsh does not split `$VAR` into words.** `FILES="a b"; swiftlint lint $FILES` (or a string of
  `-only-testing:` flags) passes ONE argument: lint and format check nothing and exit 0, and
  xcodebuild runs only the last suite. Use an array: `FILES=(a b)`, then `"${FILES[@]}"`.
  **Why:** on 2026-11-20 this hid a lint pass and a 30-suite test run (only one suite ran).
- **`make build-app` can hide a compile error.** It pipes through xcbeautify, which may print
  only "Error 65" with no `error:` line. Rerun the xcodebuild line without the pipe into a log and
  grep it for `error:`.
- **A locked screen stops every test run.** The test bundles are hosted in `supacode.app`; while
  the Mac's screen is locked the build finishes (`Validate supacode.app`) and the test session
  never starts (the host hangs in `XCTestDriver _prepareTestConfigurationAndIDESession`), for
  `make test` and for one suite alike, signed or not. Check `ioreg -n Root -d1 -a | grep -A1
  IOConsoleLocked`; ask the owner to unlock, do not restart `testmanagerd`. **Why:** on
  2026-11-17 three probes hung 30–40 min each until the owner unlocked the screen.
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

Writing test code (TestStore, TestClock, `@Shared`, imports, targets, fixtures): [[test-code-traps]].
