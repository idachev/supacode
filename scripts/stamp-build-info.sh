#!/usr/bin/env bash
# Writes the build clock and git SHA into the app Info.plist so About can show
# them. Runs after the plist exists and before the bundle is signed.
set -euo pipefail

plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
if [[ ! -f "${plist}" ]]; then
  echo "error: built Info.plist not found at ${plist}" >&2
  exit 1
fi

sha="unknown"
if git -C "${SRCROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  sha="$(git -C "${SRCROOT}" rev-parse --short HEAD)"
  if [[ -n "$(git -C "${SRCROOT}" status --porcelain)" ]]; then
    sha="${sha}-dirty"
  fi
fi
when="$(date '+%Y-%m-%d %H:%M')"

write_key() {
  local key="$1"
  local value="$2"
  if /usr/libexec/PlistBuddy -c "Print :${key}" "${plist}" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :${key} '${value}'" "${plist}"
  else
    /usr/libexec/PlistBuddy -c "Add :${key} string '${value}'" "${plist}"
  fi
}

write_key SupacodeBuildDate "${when}"
write_key SupacodeBuildCommit "${sha}"
echo "stamped ${when} ${sha}"
