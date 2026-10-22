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
