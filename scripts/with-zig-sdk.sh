#!/usr/bin/env bash
# Isolate the older SDK override to the Zig process and its children.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPACODE_ZIG_SDKROOT="$("$script_dir/select-zig-sdk.sh")"
export SUPACODE_ZIG_SDKROOT
export PATH="$script_dir/zig-sdk-bin:$PATH"
exec "$@"
