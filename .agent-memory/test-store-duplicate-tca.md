---
name: test-store-duplicate-tca
description: Read before passing a Store built in a test to app code that reads its state: TCA is linked twice and the observable read traps at 0.000 s.
paths:
  - supacodeTests/**
  - supacode/Features/RemoteAccess/**
---

# A test-built Store crashes on an observable state read

ComposableArchitecture is linked statically into both `supacode.debug.dylib` and each test bundle
(`nm` shows `Store.currentState` defined in both). A `Store` created in a test file gets the test
copy's generic metadata. Reading its state through the dynamic member (`store.repositories`:
`Store.subscript` -> `state` -> `observableState` -> `PerceptionRegistrar.access`) fails
`unsafeDowncast`'s debug precondition and traps (EXC_BREAKPOINT). xcodebuild reports only
`failed (0.000 seconds)` with no issue; the frame is in `~/Library/Logs/DiagnosticReports/supacode-*.ips`.
This happens both in app code the test drives and in the test's own checks.

Read with `store.withState(\.field)`, which bypasses the registrar, on every path a test drives with a
real `Store`. `TestStore` is not affected.

**Why:** on 2026-11-10 the remote `worktree.new` router tests on a real `Store` crashed at 0.000 s in
`make test`; switching the reads to `withState` fixed them (c4631fcc).
