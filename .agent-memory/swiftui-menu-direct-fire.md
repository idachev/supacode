---
name: swiftui-menu-direct-fire
description: Read before firing a main-menu item yourself (Cyrillic shortcuts, local key monitors) or when a shortcut runs another window's or an older focus's action.
paths:
  - supacode/Infrastructure/Ghostty/GhosttySurfaceView.swift
  - supacode/App/supacodeApp.swift
  - supacode/Commands/*.swift
---

# A SwiftUI menu item fired directly runs a stale action unless its menu was refreshed

SwiftUI's command menus (`SwiftUIMenu`, delegate `AppKitMainMenuItem`) put the current
`@FocusedValue` actions into their items only in the delegate's `menuNeedsUpdate(_:)`. AppKit's
own key-equivalent path calls it first; `NSMenu.update()` does not reach it. An item fired directly
(`NSApp.sendAction` on a scanned item, as the Cyrillic path does) without that refresh ran the
action of an older focus: ⌘W closed the main window's tab, or did nothing, while the Remote Mac
window was key, and ⌘D sent the pane focused before ("no such pane"). Only the Bulgarian layout
was hit; the US layout goes through AppKit's own path.

Before a direct fire call `item.menu?.delegate?.menuNeedsUpdate?(menu)` (then `update()`), and
resolve the chord again: the refresh may replace the item (`refreshedItem` in
`GhosttySurfaceView`). To see such a bug, log the fired closure's captured values against the live
state (a temporary file logger; the dev build has no unified log, see [[dev-build-logs]]).

**Why:** on 2026-11-20 a fix with `update()` alone passed its unit test and failed live; a probe
test hosted in the app showed the delegate answers only `menuNeedsUpdate:`.
