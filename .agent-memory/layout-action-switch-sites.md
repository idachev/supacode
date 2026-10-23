---
name: layout-action-switch-sites
description: Read when adding a LayoutFeature.Action case or a TerminalClient.Command case; lists every switch that must learn it, including one with a default.
paths:
  - supacode/Features/Terminal/Reducer/LayoutFeature.swift
  - supacode/Clients/Terminal/TerminalClient.swift
---

# Switch sites for new layout actions and terminal commands

A new `LayoutFeature.Action` case must be classified in four places:

1. `LayoutFeature.isExemptFromConsistencyCheck` (exhaustive).
2. `TerminalsFeature.canAffectVisibility` (exhaustive). A wrong `false` leaves visible tabs unwoken or
   hidden ones un-armed for hibernation.
3. `RecentTerminals.canChangeCurrentTab` (exhaustive).
4. `RecentTerminals.canRemoveTabs` has a `default` branch, so the compiler does NOT flag a new
   tab-removing action; add it by hand or stale Recent Terminals entries survive.

A new `TerminalClient.Command` case must be listed in both `return false` lists of
`WorktreeTerminalManager` (`handleSearchCommand` and `handleBindingActionCommand`) and handled once
(settings flips go to `handleManagementCommand`).
</content>
