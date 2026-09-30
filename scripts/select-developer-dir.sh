#!/usr/bin/env bash
# Prints the Developer dir of a full Xcode with a native or fallback macOS SDK
# that Zig 0.15.2 can link. Shared by build scripts and doctor. Exit 1 with
# an actionable message when none is installed.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Require full Xcode plus either its native SDK or a compatible Zig-only fallback.
is_zig_linkable() {
  local dir="$1"
  [ -x "${dir}/usr/bin/xcodebuild" ] || return 1
  DEVELOPER_DIR="$dir" "$script_dir/select-zig-sdk.sh" >/dev/null 2>&1
}

# Honor an explicit DEVELOPER_DIR when it is itself linkable.
if [ -n "${DEVELOPER_DIR:-}" ] && is_zig_linkable "${DEVELOPER_DIR}"; then
  printf '%s\n' "${DEVELOPER_DIR}"
  exit 0
fi

candidates=()
# Known-good versioned Xcodes first (newest <= 26.3, underscore and hyphen
# naming), so a machine whose default is a newer non-linkable Xcode (CI on 26.5)
# still finds a linkable one instead of stopping at the default.
for app in \
  /Applications/Xcode_26.3*.app /Applications/Xcode-26.3*.app \
  /Applications/Xcode_26.2*.app /Applications/Xcode-26.2*.app \
  /Applications/Xcode_26.1*.app /Applications/Xcode-26.1*.app \
  /Applications/Xcode_26.0*.app /Applications/Xcode-26.0*.app; do
  [ -d "${app}" ] && candidates+=("${app}/Contents/Developer")
done
# Then the currently-selected and unversioned default, covering a linkable Xcode
# at a non-standard path.
if current="$(xcode-select -p 2>/dev/null)" && [ -n "${current}" ]; then
  candidates+=("${current}")
fi
[ -d /Applications/Xcode.app ] && candidates+=("/Applications/Xcode.app/Contents/Developer")

# Guard the empty case: bash 3.2 errors on `"${arr[@]}"` under `set -u`.
for dir in ${candidates[@]+"${candidates[@]}"}; do
  if is_zig_linkable "${dir}"; then
    printf '%s\n' "${dir}"
    exit 0
  fi
done

cat >&2 <<'EOF'
error: no Xcode with a Zig-compatible SDK found.

  Zig 0.15.2 needs a macOS SDK <= 26.3. Newer Xcodes can use a compatible
  Command Line Tools SDK for Zig while Swift keeps the native Xcode SDK.
  Set SUPACODE_ZIG_SDKROOT to another compatible SDK, or install Xcode 26.3:

    https://developer.apple.com/download/all/?q=Xcode%2026.3

  Then accept its license and finish first launch (DEVELOPER_DIR alone is not
  enough until this completes):

    sudo DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -license accept
    sudo DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -runFirstLaunch

  No global `xcode-select -s` is needed. The build picks it up automatically.
EOF
exit 1
