# Fork Notes

This repository is a fork of [supabitapp/supacode](https://github.com/supabitapp/supacode).
The fork's working branch is `idachev-supacode` on the `idachev` remote; `main` only mirrors
upstream `origin/main`. This file lists where the fork deliberately differs from upstream, so
each upstream merge can keep those differences.

## License Enforcement Is Off By Default

Upstream 0.11.0 added licensing: a release build asks for a license after five local worktree
creations, checks Team entitlement leases, and blocks updates past a license's included
updates. The fork keeps all of that code, so upstream merges apply cleanly, but switches the
enforcement off with one build setting.

| Setting | Where | Default | Effect |
| --- | --- | --- | --- |
| `SUPACODE_LICENSE_ENFORCED` | `Configurations/Project.xcconfig` | `NO` | `YES` adds the `SUPACODE_LICENSE_ENFORCED` Swift compilation condition |

`LicenseBuild.isEnforced` (`supacode/Features/License/Models/LicenseSnapshot.swift`) is `true`
only for a Release build compiled with that condition:

```swift
#if DEBUG || !SUPACODE_LICENSE_ENFORCED
  false
#else
  true
#endif
```

- Debug builds (`make build-app`, `make install-dev-build`) never enforce, the same as upstream.
- Release builds (`make archive`) enforce only when the setting is `YES`.
- Settings → License stays visible either way; with enforcement off it limits nothing.

To build a Release with upstream licensing, set the value to `YES` in
`Configurations/Project.xcconfig`, or pass it in an `XCODE_XCCONFIG_FILE` override (the way
`.github/workflows/main.yml` passes `SUPACODE_RELEASE_DAY`), or on the command line:

```bash
xcodebuild -workspace supacode.xcworkspace -scheme supacode -configuration Release SUPACODE_LICENSE_ENFORCED=YES build
```

Check which condition a configuration gets:

```bash
xcodebuild -workspace supacode.xcworkspace -scheme supacode -configuration Release -showBuildSettings | grep SWIFT_ACTIVE_COMPILATION_CONDITIONS
```

### Keeping It On Upstream Merges

- A conflict in `Configurations/Project.xcconfig` usually comes from a version bump: keep
  upstream's `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, and keep the fork's
  `SUPACODE_LICENSE_*` block at the end of the file.
- If upstream changes `LicenseBuild.isEnforced`, keep the `!SUPACODE_LICENSE_ENFORCED` term in
  its condition.
- If upstream adds a new licensing gate, make sure it reads `LicenseBuild.isEnforced` or
  `LicenseClient.isEnforced`, so the setting still switches it off.

## Sidebar: Active Above Pinned

Upstream shows the global **Pinned** section first and keeps a pinned row in **Pinned** even
while an agent or script runs in it. The fork shows **Active** first, and **Active** claims its
rows before **Pinned**:

- A pinned worktree that starts an agent or a script moves into **Active**. It goes back to
  **Pinned** when it no longer classifies as active (`SidebarActiveClassification`).
- With **Group Active Rows** off, the row stays in **Pinned**.
- Hotkey slots and the menu bar list follow the same order: Active, then Pinned.
- Rows inside **Active** keep upstream's alphabetical order (unread first when "move notified
  worktree to top" is on). A newest-activity order was tried and reverted (`02e78b0c`):
  rows jumped on every agent or notification event.

The change lives in `computeHighlightHoists` and `computeSidebarStructure`
(`supacode/Features/Repositories/BusinessLogic/SidebarStructure.swift`) and in
`MenuBarSections.entries` (`supacode/Features/App/Models/MenuBarNotificationList.swift`).

### Keeping It On Upstream Merges

- If upstream edits `computeHighlightHoists`, keep Active computed first with no exclusions,
  and Pinned computed with `excluding:` the Active rows.
- Keep `.active` before `.pinned` in the sections list, in `computeHotkeyOrdering`, and in
  `MenuBarSections.entries`.
- The tests `pinnedActiveRowMovesIntoActiveAboveThePinnedSection` and
  `entriesRenderInActiveThenPinnedThenUnreadOrder` fail if a merge brings back the upstream order.

## Machine-Local Makefile Overrides (`Local.mk`)

The `Makefile` includes an optional, gitignored `Local.mk` from the repository root
(`-include $(CURRENT_MAKEFILE_DIR)/Local.mk`). Put settings there that belong to one machine
only, such as a signing identity. A missing `Local.mk` changes nothing.

### Stable Code Signing For Dev Builds

By default `make build-app` signs ad-hoc (Tuist sets `CODE_SIGN_IDENTITY = "-"` on the target).
macOS TCC identifies an ad-hoc app by the hash of each build, so every rebuild and install
loses the granted permissions (Accessibility, Screen Recording, Microphone and others).
Signing every build with the same certificate keeps them.

1. Create a self-signed code-signing certificate in the login keychain (Keychain Access →
   Certificate Assistant → Create a Certificate, type Code Signing), then find its SHA-1:

   ```bash
   security find-identity -v -p codesigning
   ```

2. Create `Local.mk` in the repository root:

   ```make
   build-app: XCODEBUILD_FLAGS += CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=<SHA-1> DEVELOPMENT_TEAM=
   ```

   The settings go on the `xcodebuild` command line, because a project-level xcconfig cannot
   override the target-level `CODE_SIGN_IDENTITY`. The target-specific variable reaches
   `build-app` and the targets that depend on it (`install-dev-build`, `run-app`); `make test`
   and `make archive` are not affected.

3. Run `make install-dev-build`. On the first signed build macOS asks whether `codesign` may
   use the key: choose **Always Allow**. Otherwise the build fails with `Error 65`, and
   xcbeautify hides the reason.

4. Check the installed app:

   ```bash
   codesign -dr - /Applications/supacode.app
   ```

   Expect `designated => identifier "app.supabit.supacode" and certificate leaf = H"..."` and
   no `adhoc` in `codesign -dv --verbose=2 /Applications/supacode.app`. Entitlements and the
   hardened runtime come from the target, so they stay the same.

macOS may ask for the permissions once more after the first signed install. Later rebuilds
keep them. A build from the Xcode GUI or a plain `xcodebuild` without these flags is still
signed ad-hoc.
