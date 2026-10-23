---
name: split-per-tab-invariants
description: Read before changing PaneLayout, LayoutFeature or any code that picks a pane or enumerates contents while the split-per-tab layout mode exists.
paths:
  - supacode/Features/Terminal/**/*.swift
---

# Split per tab: flat panes, one tree per group

In split-per-tab mode `PaneLayout.panes` is flat: it holds every pane of every group. `tree` and
`focusedPaneID` belong to the ACTIVE group only; parked groups keep their own tree, focus and zoom.

- **Enumerating contents:** all-contents readers (the launch reaper, `reconcileContentLifecycle`,
  Recent Terminals pruning, the sidebar projection, `allContentIDs`) MUST use flat `panes`. A helper that
  walks only the active group drops parked terminals, and the reaper then kills their sessions.
- **Picking a pane for focus:** never fall back to `panes.first`. `LayoutFeature.focus()` activates the
  owning group of a parked pane, so a fallback from flat `panes` switches the visible group by accident.
  Pick from the active tree (`layout.tree.leaves()`) or from the relevant group's tree
  (`groupID(containingPane:)`). `panes.first` is fine only in tabs-per-split mode.
  **Why:** the 2026-10-23 self-review found `PaneWindowManager.returnFocus` doing this; it was fixed with
  `PaneWindowFocusReturn.target`.
- **Mode conversion and group switches** are pure `PaneLayout` transforms in one reducer action. They never
  call close, collapse, reap or `contentRuntime.remove`, and never remint a `TabID` or `ContentID` (running
  shells keep `SUPACODE_TAB_ID`; blocking scripts and Recent Terminals key on `TabID`).
- **Tree actions on a parked pane** edit the tree that owns the pane (`modifyTree(containing:)`). Only
  zoom activates the group, and it calls `activateGroup` directly, not `focus()`: through `focus()` the
  preserve-zoom policy moves the zoom and the toggle then clears it. A split of a parked pane grows that
  group in the background and switches only when `spec.select` is set; entering window mode clears the
  owning tree's zoom without switching.

Persistence of the grouping: [[layouts-persistence]]. New actions: [[layout-action-switch-sites]].
</content>
