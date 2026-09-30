#!/usr/bin/env bash
# Select a macOS SDK whose arm64 stubs Zig 0.15.2 can link. Swift continues
# using the selected Xcode's native SDK; only Zig uses this fallback.
set -euo pipefail

is_linkable_sdk() {
  local sdk="$1" version
  [ -f "$sdk/SDKSettings.plist" ] || return 1
  version="$(/usr/libexec/PlistBuddy -c 'Print :Version' "$sdk/SDKSettings.plist" 2>/dev/null)" || return 1
  [ "$(printf '%s\n26.3\n' "$version" | sort -V | tail -1)" = "26.3" ] || return 1
  grep -q 'arm64-macos' "$sdk/usr/lib/libSystem.tbd"
}

if [ -n "${SUPACODE_ZIG_SDKROOT:-}" ]; then
  if is_linkable_sdk "$SUPACODE_ZIG_SDKROOT"; then
    printf '%s\n' "$SUPACODE_ZIG_SDKROOT"
    exit 0
  fi
  echo "error: SUPACODE_ZIG_SDKROOT is not a Zig 0.15.2-compatible macOS SDK." >&2
  exit 1
fi

native_sdk="$(/usr/bin/xcrun --sdk macosx --show-sdk-path 2>/dev/null)" || native_sdk=""
if is_linkable_sdk "$native_sdk"; then
  printf '%s\n' "$native_sdk"
  exit 0
fi

for sdk in /Library/Developer/CommandLineTools/SDKs/MacOSX{26.3,26.2,26.1,26.0,15.4,15}.sdk; do
  if is_linkable_sdk "$sdk"; then
    printf '%s\n' "$sdk"
    exit 0
  fi
done

echo "error: Zig 0.15.2 needs a macOS SDK <= 26.3. Install Xcode 26.3 or set SUPACODE_ZIG_SDKROOT to a compatible SDK." >&2
exit 1
