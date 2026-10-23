# Split per tab layout mode

Implement this spec in the run checkout on branch `captain/20261023-split-per-tab`.
Read the whole file before editing. Several writers work against it in
parallel (see **Task split**), so the names, signatures, action payloads,
persisted keys and wire formats below are a contract. Change one only through
the spec review loop, never in code alone.
Do not open a GitHub issue or pull request, and do not push.
Commit only your task's files, by path.

## Goal

Supacode gets one global setting, **Terminal Layout**, with two values:

- **Tabs in Each Split** (`tabsPerSplit`, the default): today's layout since
  upstream #786 (58438348). One split tree per worktree; every split pane has
  its own tab strip.
- **Splits in Each Tab** (`splitPerTab`, SPT): the pre-#786 behaviour. One
  tab strip per worktree; every top-level tab holds its own split tree; every
  split leaf is exactly one terminal.

Switching the setting converts every worktree's layout live, in one reducer
action per worktree. No terminal closes, no zmx session is killed, no
`TabID` or `ContentID` changes, so running shells keep their
`SUPACODE_TAB_ID` / `SUPACODE_SURFACE_ID`, blocking scripts keep their
tracking, and Recent Terminals keeps its history.

Vocabulary in this spec:

- **group**: an SPT top-level tab. It owns one split tree. The user sees it
  as a tab in the worktree-level strip. The word "group" never appears in the
  UI; it is the code name.
- **content tab**: a `TabItem`. In SPT every pane holds exactly one, so a
  content tab is a split leaf (a v1 "surface"). It keeps being the CLI's
  addressable "tab".
- **active group**: the group whose tree is on screen. **Parked groups** are
  the others.

## Decisions

Settled before this spec (not reopened here):

- **ВП1** (owner): one GLOBAL setting in Settings, no per-worktree choice.
  The default is the current v2 behaviour, so every existing test and every
  stored layout stays valid.
- **ВП2** (owner): live conversion when the mode switches; no terminal may
  close. v2 → SPT: the current split, each pane showing its selected tab,
  becomes group 1; every other tab of every pane becomes its own group with
  one pane. SPT → v2: the active group's split becomes the pane arrangement;
  the tabs of all other groups go as tabs into the focused pane (like
  `LayoutsMigrator`).
- **АР1**: model = flat `panes` (every pane of every group) plus one split
  tree per group. `tree` / `focusedPaneID` stay the ACTIVE group. Parked
  groups hold their own tree, focus and zoom. Not a child `LayoutFeature` per
  tab, not a view-only projection, not per-group panes.
- **АР2**: persistence keeps `schemaVersion` 2. The record's `layout` is
  always the consistent v2 projection (the SPT → v2 conversion). The grouping
  goes into an optional sidecar on `LayoutRecord`. On read, a sidecar that
  validates rebuilds the groups, else the v2 → SPT rule runs. Nothing is ever
  dropped. Layouts live in UserDefaults key `layoutsFile`; `layouts.json` is
  legacy input only. The trade-off against a schema v3 bump is in
  **Persistence**, for the reviewer to judge.
- **АР3**: v2 → SPT group order = group 1, then tree-leaf order, and within a
  pane, strip order.
- **АР4**: `tab new` (CLI / deeplink, also with a pane anchor) in SPT creates a
  new group.
- **АР5**: `tab move` (move a tab to a new split) in SPT is refused with a
  clear error message.
- **АР6** (coordinator, confirmed after the first draft): `openFileWithScript`
  placement in SPT follows **ДР7**. v1 had no `openFileWithScript` (#796 came
  after #786), so the rule is defined here: `.tab` → new group, `.splitRight`
  stays a split.
- **Conversion invariant**: a pure `PaneLayout → PaneLayout` transform in one
  reducer action. It never reaps, closes or collapses, never remints a
  `TabID` or `ContentID`, cancels close alerts and exits window mode for the
  panes it dissolves, runs for ALL layouts in `TerminalsFeature` (hostless
  hydrated ones too), and runs at hydration when the stored shape disagrees
  with the mode.

Added by this spec (visible outside it or hard to undo; each can be changed
in review):

- **ДР1 Setting identity.** Enum `TerminalLayoutMode` in
  `SupacodeSettingsShared`, cases `tabsPerSplit` / `splitPerTab` (raw values
  equal the case names), `GlobalSettings.terminalLayoutMode`, JSON key
  `terminalLayoutMode` in `~/.config/supacode/config.json`. UI labels
  "Tabs in Each Split" / "Splits in Each Tab". Rejected: a `Bool`
  (`splitPerTabEnabled`), because a third layout would need a new key; the
  names `v1` / `v2`, because they mean nothing to a user.
- **ДР2 The reducer follows the layout's own mode, not the setting.**
  `LayoutFeature.State.mode` (live-only, never persisted) records which shape
  the layout is in. Every SPT branch in `LayoutFeature`, the views and the
  manager reads it. Only `TerminalsFeature` reads the setting
  (`@Shared(.settingsFile)`) when it creates or hydrates a layout, and
  `layoutModeChanged(_:)` carries the new mode explicitly. Rejected: reading
  `@Shared(.settingsFile)` inside `LayoutFeature`, because between a config
  edit and the conversion a layout would be read under the wrong mode and
  the invariant gate would trap.
- **ДР3 Group identity.** `PaneGroupID`, a UUID wrapper shaped like `PaneID`,
  minted with `@Dependency(\.uuid)`. Internal: persisted only in the sidecar,
  never accepted or printed by the CLI or deeplinks. Rejected: identifying a
  group by one of its pane ids (unstable when that pane closes).
- **ДР4 One content tab per pane in SPT.** Enforced by
  `PaneLayout.isSplitPerTabShape` and the reducer gate. In SPT `moveTab`,
  `moveTabToSplit` and `moveTabToSpanningSplit` are refused (log at info,
  `.none`); `newTab` and `contentRequestedNewTab` create a group instead.
- **ДР5 Closing the active group's last pane** activates the previous group in
  strip order, else the next one. This mirrors v2's close-tab selection
  (`reduceCloseTab`: previous tab, else first).
- **ДР6 New group position.** A selected new group is inserted right after the
  active group; a background one (`select: false`) is appended. Mirrors v2's
  `reduceNewTab` rule for strips.
- **ДР7 `openFileWithScript` in SPT.** `openFileWithScript` does not exist at
  `58438348^`: it arrived in 3f26643b (#796), a descendant of 58438348
  (`git merge-base --is-ancestor 58438348 3f26643b` succeeds; `git grep
  openFileWithScript 58438348^` finds nothing). So there is no v1 behaviour to
  mirror. Rule: every `.tab(paneToken:)` placement from
  `WorktreeTerminalManager.openFilePlacement` becomes a new group in SPT
  (v1's "tab" was top-level, and АР4 already routes an anchored `newTab` to a
  new group). `.splitRight` stays a split of the active group's pane. No code
  change in `openFileWithScript` is needed; the reducer's SPT `newTab`
  routing produces it. Confirmed as АР6.
- **ДР8 CLI output fields.** In SPT, every `tab list` and `pane list` response
  entry gains `"group": "<n>"` (1-based index of the owning group in strip
  order), and pane entries of the active group gain `"activeGroup": "1"`. In
  v2 mode the entries are byte-for-byte unchanged. The CLI's printed line
  (`ListFormatting.line(id, focused:)`) does not change. Rejected: a public
  group id (ДР3).
- **ДР9 Menu titles.** "New Terminal Tab", "Rename Tab" and "Select Tab N" keep
  their titles in both modes (in SPT "tab" is the top-level tab, as in v1).
  The ⌘W item reads "Close Tab" in v2 and "Close Terminal" in SPT (v1's
  title), because in SPT ⌘W closes the focused split, not the whole tab.
  `WindowCommands` already reads `@Shared(.settingsFile)` in its body, so the
  title change needs no `FocusedAction` token. This is the one place that
  reads the setting instead of a layout's `mode` (ДР2): the menu bar has no
  layout scope, and the two differ only for the single `settingsChanged`
  turn before the conversion lands.
- **ДР10 Focusing a pane activates its group, windowed panes included.** This
  keeps the invariant "`focusedPaneID` is a leaf of the active tree" with no
  exception. A click into a pane window of a parked group therefore switches
  the main window to that group. See ОП11.
- **ДР11 v2 mode ignores a sidecar.** Hydration in v2 mode uses the record's
  `layout` as is (it already is the v2 projection); the next write for that
  worktree drops the sidecar.
- **ДР12 Sidecar validation is all or nothing.** Any failed check discards
  the whole sidecar and runs the v2 → SPT rule on the base layout. Rejected:
  partial unfold (more code paths for a case that only follows an old build
  editing the record).
- **ДР13 Ghostty `goto_tab` in SPT targets groups.** `contentRequestedGotoTab`
  selects among groups (previous / next / last / position). The conduit drops
  `goto_tab` today (`LayoutSurfaceConduit.swift` L46-53), so this only fixes
  the semantics for when it is wired.
- **ДР14 Conversion route.** `TerminalsFeature.layoutModeChanged(mode)`
  returns one `.send(.layouts(.element(id:, action: .convertMode(to: mode))))`
  per layout, so the invariant gate, the three exhaustive switches and
  `layoutChangeObserver.layoutChanged` all run per worktree without new
  plumbing, hostless layouts included.

Owner answers (settled after the first draft; details in **Owner-settled
behaviour**):

- **ОП7** (ОТ1): the group title is derived from the focused pane's content
  tab (`TabTitle.resolved`); rename sets `customTitle` on that `TabItem`; no
  separate group title state.
- **ОП9** (ОТ3): only the ВП2 lossy rule; the last SPT grouping is NOT
  remembered for a lossless switch back. The relaunch sidecar (АР2) stays.
- **ОП11** (ОТ4): window mode is allowed per pane in SPT, as in v2; panes the
  conversion dissolves exit window mode.
- **ОП14** (ОТ9): NO separate "Close Group" / "Close Tab" verb: no new menu
  item, shortcut, strip close button or CLI verb. ⌘W closes the focused pane
  (terminal); closing the last pane of a group closes the group through the
  internal "group emptied" path (`promoteNeighbourOfEmptiedActiveGroup`, and
  the parked-group removal in collapse).

## Non-goals

- No per-worktree or per-repository mode (ВП1).
- No public group id, no new CLI noun, no new deeplink case (ДР3, ДР8).
- No schema v3 (АР2).
- No change to v2 behaviour. With the default mode, every existing test must
  pass unchanged.
- No change to Ghostty topology actions: the conduit keeps dropping
  `new_tab`, `close_tab`, `goto_tab`, `move_tab`.
- No group-to-group drag of panes (moving a split leaf into another group).
  Reordering groups in the strip is in scope.
- No "Close Group" verb of any kind (ОП14).
- No lossless switch back to a remembered SPT grouping (ОП9).
- No upstream pull request.

## How the layout works today

Evidence is from the run checkout at 9be952c9; line numbers are 1-based.

- `PaneLayout` (`supacode/Features/Terminal/Models/PaneLayout.swift`
  L303-351) is `tree: SplitTree<PaneID>`, `panes: IdentifiedArrayOf<Pane>`,
  `focusedPaneID`. Its `CodingKeys` are exactly those three. Both inits repair
  a dangling focus to `panes.first?.id` (L322-323, L342).
- `isConsistent` (L388-405): tree leaves == pane ids one-to-one, no empty
  pane, selection resolves, focus exists iff panes exist, tab and content ids
  unique.
- `strippingEphemeralContent()` (L412-443) drops blocking-script tabs and any
  pane they empty, and retargets focus to `panes.first`.
- `LayoutFeature` (`Reducer/LayoutFeature.swift`) asserts
  `layout.isConsistent` after every action not in
  `isExemptFromConsistencyCheck` (L231-244, gate L256-264).
- Every close path reaps: `reduceCloseTab` (L572-591), `reduceClosePane`
  (L919-929) → `reap` (L1089) → `contentRuntime.remove(_, tombstone: true)` +
  `sessionKiller.kill`.
- `collapse` (L954-980) removes the leaf and pane, clears a pane-owned alert,
  and refocuses to `focusTargetAfterClosing` or `panes.first?.id`.
- `focus` (L1012-1024) moves `focusedPaneID` and applies `SplitZoomPolicy`.
- `TerminalsFeature` (`Reducer/TerminalsFeature.swift`) owns
  `layouts: IdentifiedArrayOf<LayoutFeature.State>`, fires
  `layoutChangeObserver.layoutChanged` after each `.layouts(.element)` action
  (L116-124), gates the hibernation re-diff on `canAffectVisibility`
  (L94-106), and hydrates in `layoutsHydrated` (L165-191), dropping
  inconsistent and colliding records.
- Hibernation visibility uses `layout.tree.visibleLeaves()` plus each pane's
  selected tab (L252-300). A pane outside the tree is hidden.
- `ContentRuntime` keys live contents by `ContentID`. The layout stores only
  ids, so moving a `ContentID` between panes or trees only remounts its
  renderer (render-host claims).
- Persistence: `LayoutsFile { schemaVersion: 2, worktrees: [String:
  LayoutRecord] }` in UserDefaults key `layoutsFile`
  (`BusinessLogic/LayoutsMigrator.swift` L38-95). `LayoutRecord` has
  explicit `CodingKeys { layout, origin }`, a tolerant `origin` decode, and
  a synthesized encoder (L9-35). The writer rebuilds each record as
  `LayoutRecord(layout: record.layout, origin: record.origin ??
  file.worktrees[key]?.origin)` (`LayoutsIncrementalWriter.swift` L83-89).
  `LayoutPersistence.record` (`BusinessLogic/LayoutPersistence.swift`)
  overlays live snapshots and titles, strips ephemeral content, clears
  live-only fields.
- The launch orphan reaper kills every zmx session not in
  `LayoutsFile.allKnownSurfaceIDs` (every record's `layout.allContentIDs`
  plus the v1 origin).

## Model

File: `supacode/Features/Terminal/Models/PaneLayout.swift`.

### New types

```swift
/// Identity of a split-per-tab group (a top-level tab). Internal: never
/// accepted or printed by the CLI or deeplinks.
nonisolated struct PaneGroupID: Hashable, Identifiable, Codable, Sendable {
  let rawValue: UUID
  init(rawValue: UUID)
  var id: UUID { rawValue }
  // single-value Codable, exactly like PaneID
}

/// A parked split-per-tab group: its own split tree (zoom included) and the
/// pane that takes focus when it becomes active.
nonisolated struct PaneGroup: Equatable, Identifiable, Codable, Sendable {
  let id: PaneGroupID
  var tree: SplitTree<PaneID>
  var focusedPaneID: PaneID
}
```

### `PaneLayout` fields

```swift
nonisolated struct PaneLayout: Equatable, Codable, Sendable {
  var tree: SplitTree<PaneID>          // the ACTIVE group's tree (v2: the only tree)
  var panes: IdentifiedArrayOf<Pane>   // every pane of every group, flat
  var focusedPaneID: PaneID?           // a leaf of `tree`
  /// Split-per-tab only: the group `tree` belongs to. nil in tabsPerSplit and
  /// in an empty layout.
  var activeGroupID: PaneGroupID? = nil
  /// Split-per-tab only: every group except the active one.
  var parkedGroups: IdentifiedArrayOf<PaneGroup> = []
  /// Split-per-tab only: every group id, active included, in strip order.
  var groupOrder: [PaneGroupID] = []
}
```

- `CodingKeys` stay `tree`, `panes`, `focusedPaneID`. The three new fields are
  never encoded; persistence carries them in the sidecar (АР2). Replace the
  doc comment "In-memory shape == persisted shape" with: "In tabsPerSplit the
  in-memory shape is the persisted shape; a split-per-tab layout persists as
  its v2 fold plus a `SplitPerTabSidecar`."
- `encode(to:)` gains `assert(activeGroupID == nil, "Encode the fold, not a split-per-tab layout.")`.
- The existing three-argument `init` and the decoder keep their meaning (no
  groups, focus repaired to `panes.first`). They never build an SPT value.
- New memberwise-style init used by conversions and tests, with NO focus
  repair:
  `init(tree:panes:focusedPaneID:activeGroupID:parkedGroups:groupOrder:)`.

### Invariants

`isConsistent` stays mode-agnostic and gains the group checks. A v2 layout
(`activeGroupID == nil`) passes exactly the checks it passes today.

1. The leaves of `tree` and of every `parkedGroups[i].tree` are pairwise
   disjoint, contain no duplicate, and their union equals `Set(panes.ids)`.
2. No empty pane; every `selectedTabID` resolves; tab ids unique; content ids
   unique (as today).
3. `focusedPaneID`: nil iff `panes` is empty; otherwise a leaf of `tree`
   (today it only had to be in `panes`, which equals the tree's leaves in v2).
4. `activeGroupID == nil` ⇒ `parkedGroups.isEmpty && groupOrder.isEmpty`.
5. `activeGroupID != nil` ⇒ `!panes.isEmpty`, `!tree.isEmpty`, `groupOrder`
   has no duplicate, `Set(groupOrder) == Set(parkedGroups.ids) ∪ {active}`,
   `active ∉ parkedGroups.ids`.
6. Every parked group: `!tree.isEmpty` and `focusedPaneID ∈ tree.leaves()`.

New predicates:

```swift
/// Split-per-tab shape: every pane holds exactly one tab, and a non-empty
/// layout has an active group.
var isSplitPerTabShape: Bool   // panes.allSatisfy { $0.tabs.count == 1 } && (panes.isEmpty || activeGroupID != nil)

/// The gate predicate: structure plus the shape the mode demands.
func isConsistent(for mode: TerminalLayoutMode) -> Bool
// .tabsPerSplit: isConsistent && activeGroupID == nil
// .splitPerTab:  isConsistent && isSplitPerTabShape
```

### Lookups

The all-contents lookups (`pane(containingTab:)`, `tab(containingContent:)`,
`pane(forToken:)`, `allContentIDs`) are unchanged and, because `panes` is
flat, cover parked groups by construction. That is the reason for АР1: the
reaper, `reconcileContentLifecycle`, Recent Terminals pruning, sidebar
`surfaceIDs`, `idExistsAnywhere` and the hydration collision checks all keep
seeing every terminal.

New, all `nonisolated`:

```swift
/// The parked group holding a pane; nil when the pane is in the active tree
/// (or unknown).
func parkedGroupID(containingPane paneID: PaneID) -> PaneGroupID?
/// The group holding a pane, active included; nil in tabsPerSplit.
func groupID(containingPane paneID: PaneID) -> PaneGroupID?
/// A group's tree and focused pane, active or parked.
func tree(ofGroup id: PaneGroupID) -> SplitTree<PaneID>?
func focusedPaneID(ofGroup id: PaneGroupID) -> PaneID?
/// 1-based strip position of a group.
func groupIndex(of id: PaneGroupID) -> Int?
/// Strip position clamped to 1...groupOrder.count, Ghostty goto_tab style.
func groupID(atIndex index: Int) -> PaneGroupID?
/// Next / previous group in strip order, wrapping; nil with fewer than 2.
func groupID(relativeToActive forward: Bool) -> PaneGroupID?
```

### Mutating helpers

```swift
/// Swaps the parked group in: the outgoing active tree and focus become a
/// parked PaneGroup (same id), the target's tree and focus become `tree` /
/// `focusedPaneID`. groupOrder is unchanged. No-op for the active group or
/// an unknown id.
mutating func activateGroup(_ id: PaneGroupID)

/// Runs `body` on the tree that holds `paneID` (active or parked) and writes
/// it back. Returns nil when no tree holds the pane.
mutating func modifyTree<R>(
  containing paneID: PaneID, _ body: (inout SplitTree<PaneID>) throws -> R
) rethrows -> R?

/// Removes a leaf from whichever tree holds it and keeps the group
/// bookkeeping consistent (see Close semantics). Does not touch `panes`.
mutating func removeLeaf(_ paneID: PaneID)

/// The active tree just emptied: promote the neighbour group (ДР5).
mutating func promoteNeighbourOfEmptiedActiveGroup()
```

`promoteNeighbourOfEmptiedActiveGroup()` never calls `activateGroup` (an empty
tree cannot be parked: it would break invariant 6 and `PaneGroup` has a
non-optional focus). It removes the emptied `activeGroupID` from `groupOrder`,
takes the neighbour (the id before it in the old `groupOrder`, else the one
after it) out of `parkedGroups`, and assigns that group's `tree`,
`focusedPaneID` and `id` directly to `tree`, `focusedPaneID` and
`activeGroupID`. When no parked group remains it sets `activeGroupID = nil`,
`groupOrder = []`, `focusedPaneID = nil`. `removeLeaf` calls it when the
leaf it removed emptied the active tree; collapse (step 5) and
`strippingEphemeralContent` reach it only through `removeLeaf`.

### Conversions (pure)

```swift
/// v2 → split-per-tab (ВП2, АР3). Requires activeGroupID == nil.
func convertedToSplitPerTab(
  mintPaneID: () -> PaneID,
  mintGroupID: () -> PaneGroupID
) -> PaneLayout

/// split-per-tab → v2 (ВП2). Returns the v2 layout and the pane ids it
/// dissolved (every pane of every parked group).
func convertedToTabsPerSplit() -> (layout: PaneLayout, dissolvedPaneIDs: Set<PaneID>)
```

`convertedToSplitPerTab` algorithm, minting order fixed so tests with
`UUID.incrementing` are deterministic:

1. Empty `panes` → return `self` unchanged (an empty SPT layout has no group).
2. Mint the active group id first: `active = mintGroupID()`.
   `groupOrder = [active]`.
3. Walk `tree.leaves()` in order (windowed placeholders included). For each
   leaf's pane, keep only its selected tab in place. For every other tab in
   strip order: mint `PaneID` then `PaneGroupID`; append
   `Pane(id: newPane, tabs: [tab], selectedTabID: tab.id)` to `panes`; append
   `PaneGroup(id: newGroup, tree: SplitTree(view: newPane), focusedPaneID: newPane)`
   to `parkedGroups`; append `newGroup` to `groupOrder`.
4. `tree`, `focusedPaneID`, zoom, and every original pane id are unchanged.
   Tab ids, content ids, titles, `customTitle`, icon, tint and `isLocked`
   travel with the `TabItem` value.

`convertedToTabsPerSplit` algorithm:

1. `activeGroupID == nil` → return `(self, [])`.
2. Home pane = `focusedPaneID` (always in the active tree).
3. For each id in `groupOrder` except the active one, for each leaf of that
   group's tree in `leaves()` order: append the pane's tab to the END of the
   home pane's strip, remove the pane from `panes`, insert its id into
   `dissolvedPaneIDs`.
4. The home pane's `selectedTabID` is unchanged, so the visible terminal does
   not move. `tree`, zoom and focus are the active group's.
5. Clear `activeGroupID`, `parkedGroups`, `groupOrder`.

Lost by SPT → v2, by design (ВП2): each parked group's split arrangement,
ratios, zoom and focus, and the parked panes' ids (a CLI token that is a bare
parked pane id stops resolving; tab and content ids keep resolving). v2 → SPT
→ v2 does not restore a background tab to its old pane, and SPT → v2 → SPT
flattens every non-active group into one-pane groups (ОП9).

### Ephemeral stripping

`strippingEphemeralContent()` becomes group-aware. For a pane it empties it
calls `removeLeaf(paneID)` (not `tree.removing` on the active tree), then
removes the pane. A focused pane that disappears retargets by mode:

- v2 (`activeGroupID == nil`): `panes.first?.id`, exactly as today
  (`PaneLayout.swift` L439-441), so the default mode's persisted focus is
  unchanged even when pane order and tree-leaf order differ.
- SPT (`activeGroupID != nil`): the active tree's first leaf, never
  `panes.first` (which can be a parked pane).

## Setting

### `GlobalSettings`

File: `SupacodeSettingsShared/Models/GlobalSettings.swift`. Follow
`HoverFocusMode` exactly (enum L96, field L187, default L284, decode
L565-568).

```swift
/// How a worktree arranges terminals: a tab strip in every split (v2), or
/// one tab strip whose tabs each hold a split tree (v1 style).
public nonisolated enum TerminalLayoutMode: String, Codable, CaseIterable, Sendable {
  /// One split tree per worktree; every split has its own tab strip. The default.
  case tabsPerSplit
  /// One tab strip per worktree; every tab has its own split tree.
  case splitPerTab

  public var label: String {
    switch self {
    case .tabsPerSplit: "Tabs in Each Split"
    case .splitPerTab: "Splits in Each Tab"
    }
  }
}
```

- Field `public var terminalLayoutMode: TerminalLayoutMode`, init parameter
  `terminalLayoutMode: TerminalLayoutMode = .tabsPerSplit`, `CodingKeys` case
  `terminalLayoutMode`.
- Tolerant decode:
  `((try? container.decodeIfPresent(String.self, forKey: .terminalLayoutMode)) ?? nil).flatMap(TerminalLayoutMode.init(rawValue:)) ?? Self.default.terminalLayoutMode`.
  A missing, mistyped or unknown value reads as the default; it never fails
  the settings file.
- Encoded always (like `hoverFocusMode`).

### Settings UI

- `SupacodeSettingsFeature/Reducer/SettingsFeature.swift`: state
  `public var terminalLayoutMode: TerminalLayoutMode`; load next to
  `hoverFocusMode` (L232), apply (L426), write back (L1235).
- `SupacodeSettingsFeature/Views/TerminalSettingsView.swift`: a `Picker`
  "Terminal Layout" over `TerminalLayoutMode.allCases`, labels from `label`,
  the default tagged with `DefaultTaggedLabel` like the pickers in
  `AppearanceSettingsView.swift` (L56, L102). Tooltip (`.help`):
  "Tabs in Each Split gives every split its own tab strip. Splits in Each Tab
  gives the worktree one tab strip whose tabs each hold their own splits.
  Switching converts open terminals in place; none are closed." No hotkey
  exists for it, so the tooltip names none. System colours, Dynamic Type.

### Propagation

`AppFeature` (`supacode/Features/App/Reducer/AppFeature.swift`), the
hibernation-flag pattern:

1. State `var lastKnownTerminalLayoutMode: TerminalLayoutMode`, next to
   `lastKnownTerminalHibernationEnabled` (L167); seeded from settings in the
   init next to L208.
2. In the `settings(.delegate(.settingsChanged))` handler next to L772:
   `let layoutModeChanged = settings.terminalLayoutMode != state.lastKnownTerminalLayoutMode`,
   then update `lastKnown`.
3. Effect next to L905-910:
   `.run { _ in await terminalClient.send(.setTerminalLayoutMode(mode)) }`.

`TerminalClient` (`supacode/Clients/Terminal/TerminalClient.swift`): new
`Command` case after `setTerminalHibernationEnabled` (L119):

```swift
/// Converts every worktree layout to the new global layout mode, live.
case setTerminalLayoutMode(TerminalLayoutMode)
```

`WorktreeTerminalManager`: add `.setTerminalLayoutMode` to BOTH exhaustive
"not mine" lists (`handleSearchCommand`'s `return false` list, L476-497, and
`handleBindingActionCommand`'s, L499-546; `handleTabCommand` ends in
`default:` at L438 and needs no case), and handle it in
`handleManagementCommand` next to L558:
`case .setTerminalLayoutMode(let mode): sendTerminals(.layoutModeChanged(mode))`.

`TerminalsFeature`: new action

```swift
/// The global layout mode changed: convert every layout in place.
case layoutModeChanged(TerminalLayoutMode)
```

Handler: the payload is only a trigger. The handler reads the CURRENT
setting, `let newMode = settingsFile.global.terminalLayoutMode`
(`@Shared(.settingsFile)`), so two quick flips whose `.run` effects arrive out
of order still end in the last setting. For every layout with
`mode != newMode`, in `layouts` order, return
`.send(.layouts(.element(id: layout.id, action: .convertMode(to: newMode))))`,
merged (ДР14). The element handler then re-diffs hibernation and fires
`layoutChanged`, which drives persistence, `paneWindows.reconcile`, surface
activity and the sidebar projection in `WorktreeTerminalManager`.

Creation and hydration read the setting:
`@Shared(.settingsFile) var settingsFile` → `settingsFile.global.terminalLayoutMode`.

- `attachLayout`: a new `LayoutFeature.State` gets `mode` = the setting.
- `layoutsHydrated`: see **Persistence → Read**.

## Reducer: `LayoutFeature`

File: `supacode/Features/Terminal/Reducer/LayoutFeature.swift`.

### State

`var mode: TerminalLayoutMode = .tabsPerSplit` — live-only, set by
`TerminalsFeature` at attach / hydrate and by `convertMode`. The default keeps
every existing `LayoutFeature.State(id:layout:)` construction valid.

The invariant gate (L256-264) asserts `state.layout.isConsistent(for: state.mode)`
instead of `state.layout.isConsistent`.

### New actions (exact)

```swift
/// Converts the layout to `mode` in place (pure transform; never closes).
case convertMode(to: TerminalLayoutMode)
/// Split-per-tab: makes a group active (strip click, ⌘1..9, next/previous).
case selectGroup(id: PaneGroupID)
/// Split-per-tab: a new group with one pane and one tab (⌘T, strip "+", CLI tab new).
case newGroup(spec: NewTabSpec)
/// Split-per-tab: reorders a group in the strip; `index` is 0-based, clamped.
case moveGroup(id: PaneGroupID, toIndex: Int)
```

Every one is ignored (log at info, `.none`) when `state.mode` does not match:
`selectGroup`, `newGroup` and `moveGroup` need `.splitPerTab`. There is no
`closeGroup` action (ОП14): a group closes only when its last pane closes.

### The three exhaustive switches

| Action | `isExemptFromConsistencyCheck` (LayoutFeature L231) | `TerminalsFeature.canAffectVisibility` (L94) | `RecentTerminals.canChangeCurrentTab` (L30) | `RecentTerminals.canRemoveTabs` (L45, has `default`) |
|---|---|---|---|---|
| `convertMode` | false | true | false (focused pane and its selected tab are unchanged by both rules) | false (no tab disappears) |
| `selectGroup` | false | true | true | false |
| `newGroup` | false | true | true | false |
| `moveGroup` | false | false (order is not visibility) | false | false |

### `convertMode(to:)`

```
guard state.mode != mode else { return .none }      // idempotent
switch mode:
  .splitPerTab:
    state.layout = state.layout.convertedToSplitPerTab(
      mintPaneID: { PaneID(rawValue: uuid()) },
      mintGroupID: { PaneGroupID(rawValue: uuid()) })
  .tabsPerSplit:
    let result = state.layout.convertedToTabsPerSplit()
    state.layout = result.layout
    for paneID in result.dissolvedPaneIDs:
      state.windowedPaneIDs.remove(paneID)
      cancelAlert(&state, ifOwnedBy: paneID)
state.mode = mode
return .none
```

- Never calls `reap`, `closeTab`, `closePane`, `collapse`,
  `contentRuntime.remove` or `provisionContent`.
- `editingTabID` is kept (the tab id survives).
- v2 → SPT: a windowed pane keeps its id and its selected tab, so it stays
  windowed; its other tabs leave the window as new groups.
- `renderEpoch` is not bumped: the host remount comes from the structural
  change, as for any split.

### Group switch inside `focus()`

`focus(_:paneID:)` (L1012) becomes:

```
guard state.layout.panes[id: paneID] != nil else { return }
if let group = state.layout.parkedGroupID(containingPane: paneID) {
  // An alert raised by a pane that is about to be parked can no longer present.
  if let owner = state.alertPaneID, state.layout.groupID(containingPane: owner) == state.layout.activeGroupID {
    cancelAlert(&state, ifOwnedBy: owner)
  }
  state.layout.activateGroup(group)
}
guard state.layout.focusedPaneID != paneID else { return }
... unchanged zoom logic, which now applies to the newly active tree ...
```

Because every selection path goes through `focus()`, these switch group with
no further change: `selectTab`, `focusPane(.pane)`, `contentRequestedFocus`,
`newTab`/`splitPane` with `select`, the CLI `tab focus` / `pane focus` /
`surface focus`, Recent Terminals picks, notification jumps.

`selectGroup(id:)`: `guard let target = state.layout.focusedPaneID(ofGroup: id)`,
then `focus(&state, paneID: target)`. Selecting the active group is a no-op.
Each group keeps its own zoom; `SplitZoomPolicy` applies inside a group only.

### Tree-mutating actions on parked panes

`splitPane`, `resizePane`, `enterWindowMode` and the matching
`contentRequested*` variants resolve the tree through
`modifyTree(containing:)` instead of `state.layout.tree`, so a background
split (CLI `pane split --background`) on a parked pane grows that parked group
without switching.

- `enterWindowMode(paneID:)`: the "a zoomed placeholder would fill the
  layout" clear (`LayoutFeature.swift` L842-844) runs on the OWNING tree, so a
  parked group never keeps a zoom on a pane that has become windowed.
- `toggleZoom(paneID:)` / `contentRequestedToggleZoom`: zooming focuses the
  pane (L1035 writes `focusedPaneID` directly). For a parked pane, first
  activate its group directly: cancel a pending alert owned by a pane of the
  outgoing active group (the same check `focus()` makes), then
  `state.layout.activateGroup(group)`. Do NOT call `focus()`: it would apply
  `SplitZoomPolicy` and, with `preservesZoomOnNavigation == true`, move the
  group's remembered zoom onto the target so the toggle clears it. Then run
  today's code unchanged on the now-active tree: `isSplit` guard,
  `focusedPaneID = paneID`, toggle relative to the group's own remembered
  zoom. Never write `focusedPaneID` to a parked pane.
- `equalizePanes` has no pane payload and keeps acting on the active tree.
- `reduceFocusPane(.direction)` keeps walking the active tree (focus is always
  in it).

### SPT branches of existing actions

| Action | SPT behaviour |
|---|---|
| `newTab(inPane:spec:)` | Same as `newGroup(spec:)`; `inPane` is ignored (АР4). Bootstraps an empty layout as group 1. |
| `contentRequestedNewTab(content:)` | `newGroup` with the spec it builds today (inherits from the content). |
| `splitPane`, `contentRequestedSplit` | Unchanged semantics, inside the anchor's group. The new pane holds one tab. |
| `closeTab`, `contentRequestedClose(.tab)`, `alert(.confirmClose)` | Closing a pane's only tab collapses the pane (existing path), with the group rules below. |
| `contentRequestedClose(.otherTabs / .tabsToTheRight)` | Empty target set → `.none` (one tab per pane). |
| `contentRequestedClose(.allTabs)` | The pane's one tab. |
| `closePane` | Unchanged, with the group rules below. |
| `moveTab`, `moveTabToSplit`, `moveTabToSpanningSplit`, `contentRequestedMoveTab` | Refused: info log, `.none` (ДР4, АР5). |
| `contentRequestedGotoTab` | Targets groups by strip position (ДР13). |
| `selectTab`, `renameTab`, `beginTabRename`, `hibernateTab`, `wakeTab`, `runtime`, `exitWindowMode` | Unchanged (they address tabs/panes, which are flat). |
| `enterWindowMode`, `toggleZoom`, `contentRequestedToggleZoom` | Owning-tree rules above. |

`newGroup(spec:)`:

1. Mint identity with `mintedIdentity` and provision with
   `provisionContent(request, …)` exactly like `reduceNewTab`
   (`origin: bootstraps ? .first : .tab`).
2. `let paneID = PaneID(rawValue: uuid())`, then
   `let groupID = PaneGroupID(rawValue: uuid())` (this order).
3. Append `Pane(id: paneID, tabs: [tab], selectedTabID: tab.id)` to `panes`.
4. Empty layout: `tree = SplitTree(view: paneID)`, `focusedPaneID = paneID`,
   `activeGroupID = groupID`, `groupOrder = [groupID]`.
5. Otherwise append `PaneGroup(id: groupID, tree: SplitTree(view: paneID), focusedPaneID: paneID)`
   to `parkedGroups`; insert `groupID` into `groupOrder` right after the
   active group when `spec.select`, else at the end (ДР6); when
   `spec.select`, `focus(&state, paneID: paneID)` (switches to it).

The CLI / deeplink creation ack (`createTabAsync`: it passes
`TabID == ContentID == mintedID`, then checks that the tab count grew by one
and the new tab's content id is the minted id) holds unchanged. Other
producers (strip "+", blocking scripts) keep passing implicit or distinct ids;
`mintedIdentity` mints them separately (`LayoutFeature.swift` L1072-1077).

### Close and collapse semantics per mode

v2: unchanged.

SPT, `collapse(&state, paneID:)`:

1. Compute the refocus target with `focusTargetAfterClosing` on the tree that
   holds the leaf (active or parked).
2. `state.layout.removeLeaf(paneID)`; remove the pane; drop it from
   `windowedPaneIDs`; clear a pane-owned alert (as today).
3. The leaf was in a parked group: if that tree is now empty, remove the group
   from `parkedGroups` and `groupOrder`; else, if the group's `focusedPaneID`
   was the pane, set it to the computed target (or the tree's first leaf).
   Active focus does not move.
4. The leaf was in the active group and the tree still has leaves: refocus as
   today, but the fallback is the active tree's first leaf, never
   `panes.first?.id`.
5. The active tree is now empty: `removeLeaf` has already run
   `promoteNeighbourOfEmptiedActiveGroup()` (previous group, else next, ДР5;
   never `activateGroup`), so `tree` / `focusedPaneID` are the promoted
   group's. Do not call `focus()` again. If no group remained, the layout is
   empty (`activeGroupID == nil`, `groupOrder == []`,
   `focusedPaneID == nil`) and the alert is cleared (as today).

## Persistence

Files: `PaneLayout.swift` (sidecar type, fold, unfold),
`BusinessLogic/LayoutsMigrator.swift` (`LayoutRecord`),
`BusinessLogic/LayoutsIncrementalWriter.swift` (merge),
`BusinessLogic/LayoutPersistence.swift` (write path),
`Reducer/TerminalsFeature.swift` (read path).

### Sidecar format

```swift
/// The split-per-tab grouping of a record whose `layout` is the v2 fold.
nonisolated struct SplitPerTabSidecar: Equatable, Codable, Sendable {
  var activeGroupID: PaneGroupID
  /// Every group id, active included, in strip order.
  var groupOrder: [PaneGroupID]
  /// Every parked group, with the panes the fold dissolved.
  var parkedGroups: [ParkedGroup]

  struct ParkedGroup: Equatable, Codable, Sendable {
    let id: PaneGroupID
    var tree: SplitTree<PaneID>      // the existing hand-written SplitTree wire format, zoom included
    var focusedPaneID: PaneID
    var panes: [PaneTab]             // one entry per leaf of `tree`, leaf order
  }

  struct PaneTab: Equatable, Codable, Sendable {
    let paneID: PaneID
    let tabID: TabID
  }
}
```

Wire keys are the property names: `activeGroupID`, `groupOrder`,
`parkedGroups`, `id`, `tree`, `focusedPaneID`, `panes`, `paneID`, `tabID`.
Ids encode as bare UUID strings (single-value containers).

`LayoutRecord` gains

```swift
/// Split-per-tab grouping over `layout`; nil for a v2 layout. Replaced on
/// every write (unlike the write-once origin).
var splitPerTab: SplitPerTabSidecar?
```

- `CodingKeys` add `splitPerTab`. The decoder reads it tolerantly like
  `origin`: `(try? container.decodeIfPresent(SplitPerTabSidecar.self, forKey: .splitPerTab)) ?? nil`,
  logging an error through `migrationLogger` when the key exists but does not
  decode. An unreadable sidecar is NOT counted in `LayoutDecodeLoss`: the base
  layout still holds every content, so nothing is lost to the reaper.
- Encoding stays synthesized: `encodeIfPresent`, so a v2 record's bytes are
  unchanged.
- `init(layout:origin:splitPerTab:)` with `splitPerTab: SplitPerTabSidecar? = nil`.

Example record (SPT, two groups; ids shortened):

```json
{
  "layout": { "tree": …, "panes": [ { "id": "P1", "tabs": [T1, T2], "selectedTabID": "T1" } ], "focusedPaneID": "P1" },
  "splitPerTab": {
    "activeGroupID": "G1",
    "groupOrder": ["G1", "G2"],
    "parkedGroups": [
      { "id": "G2", "tree": …leaf P2…, "focusedPaneID": "P2", "panes": [ { "paneID": "P2", "tabID": "T2" } ] }
    ]
  }
}
```

### Write: fold

```swift
/// The persistable pair: the v2 projection (the SPT → v2 rule) plus the
/// sidecar that rebuilds the groups. A v2 layout folds to (self, nil).
func foldedForPersistence() -> (layout: PaneLayout, sidecar: SplitPerTabSidecar?)
```

The sidecar's `parkedGroups` copy each parked `PaneGroup` and list, per leaf,
the pane's single tab id. Order of work in `LayoutPersistence.record(for:…)`:

1. Overlay live snapshots, titles and agents on the live (possibly SPT)
   layout, as today.
2. `strippingEphemeralContent()` on the live shape (group-aware).
3. Clear live-only fields, as today.
4. Fold; return `LayoutRecord(layout: folded, origin: origin, splitPerTab: sidecar)`.

`LayoutsIncrementalWriter.applyAndWriteRecords` (L83-89) rebuilds a record as
`LayoutRecord(layout: record.layout, origin: record.origin ?? file.worktrees[key]?.origin, splitPerTab: record.splitPerTab)`.
The sidecar is always replaced, never inherited from the stored record, so a
v2-mode write removes it. The no-op gate (`file != original`) still holds,
because a decoded sidecar equals the one that was encoded.

### Quit save covers hostless layouts

A mode switch converts hydrated layouts that have no host, and their 1 s
debounced save (`markLayoutDirty`, `WorktreeTerminalManager.swift`
L1546-1553) is cancelled at quit (`supacodeApp.swift` L65), while
`saveAllLayoutSnapshots` (L2004-2019) iterates `hosts` only. Fix:
`saveAllLayoutSnapshots` writes `hosts.keys ∪ layoutDirtyTasks.keys`
(every worktree with a pending debounced save, host or not). In
`applicationWillTerminate` the dirty ids are captured before
`cancelPendingLayoutSaves()` clears them: either call order is swapped
(save, then cancel; the save runs synchronously on the writer queue) or
`cancelPendingLayoutSaves` returns the ids it cancelled and
`saveAllLayoutSnapshots(extraWorktreeIDs:agentsBySurface:)` takes them. T6
picks one; the test drives it with the injected `layoutDebounceSleep`, no
clock advance, and asserts the hostless record holds the converted shape.

### Read: unfold

```swift
/// Rebuilds the split-per-tab layout from a v2 base and its sidecar; nil when
/// any check fails (ДР12).
func unfolding(_ sidecar: SplitPerTabSidecar) -> PaneLayout?
```

Checks, all required:

1. `self.activeGroupID == nil` and `self.isConsistent`.
2. `sidecar.parkedGroups` ids are unique (checked on the array, before any
   `IdentifiedArray` is built); `sidecar.groupOrder` has no duplicates,
   contains `activeGroupID`, and equals `{activeGroupID} ∪ parkedGroups.ids`
   as a set; no parked id equals `activeGroupID`.
3. Every `PaneTab.tabID` exists in the base exactly once across the sidecar
   and is never the selected tab of the base's focused pane.
4. Every `PaneTab.paneID` is unique across the sidecar and absent from the
   base's pane ids.
5. Each parked group: `Set(tree.leaves()) == Set(panes.map(\.paneID))`,
   no duplicate leaf, `focusedPaneID ∈ tree.leaves()`.
6. After moving each sidecar tab out of its base pane into
   `Pane(id: paneID, tabs: [tab], selectedTabID: tab.id)`, no base pane is
   empty and the result `isSplitPerTabShape` (so an old build that added a
   tab to an active pane fails here and falls back).

The unfolded value must also pass `isConsistent(for: .splitPerTab)`; if it
does not, `unfolding` returns nil (fallback, ДР12).

Pane order is canonical, not the live order (the sidecar does not store the
flat `panes` order, and `activateGroup` never reorders `panes`): the base
panes in their stored order, then the parked panes in `groupOrder`, then
tree-leaf order. Nothing renders `panes` order, and the fold of an unfolded
layout is the same record, so the writer's no-op gate holds.

Unfolded: base panes keep their selection (repaired to the first remaining
tab only if the selected tab moved out, which check 3 excludes for the
focused pane); `activeGroupID`, `groupOrder`, `parkedGroups` come from the
sidecar.

`TerminalsFeature.layoutsHydrated` per record, after today's consistency and
collision checks on `record.layout` (unchanged; they see every content id
because the base holds all of them):

```
let mode = settingsFile.global.terminalLayoutMode
let layout: PaneLayout
switch mode {
case .tabsPerSplit: layout = record.layout                      // ДР11
case .splitPerTab:
  layout = record.splitPerTab.flatMap { record.layout.unfolding($0) }
    ?? record.layout.convertedToSplitPerTab(mintPaneID: …uuid…, mintGroupID: …uuid…)
}
state.layouts.append(LayoutFeature.State(id: worktreeID, layout: layout, mode: mode))
```

`TerminalsFeature` gains `@Dependency(\.uuid) private var uuid` for the
minting. A sidecar that fails to unfold logs at error level once per
worktree.

### Reaper safety

- `LayoutsFile.allKnownSurfaceIDs` is unchanged and complete: the fold moves
  every parked tab into the base layout, so every content id of every group
  is in `record.layout.allContentIDs`.
- An older build (upstream or the fork before this feature) decodes the
  record as plain v2 (its `LayoutRecord.CodingKeys` ignore `splitPerTab`),
  passes `isConsistent`, restores every terminal as tabs in the focused pane,
  and reaps nothing. When it writes the record it drops the sidecar; the next
  SPT launch re-derives groups with the v2 → SPT rule. Only grouping is lost,
  never a session.
- `SidebarPersistenceMigrator` and `SettingsRelocationMigrator` decode and
  re-encode `LayoutsFile` through `LayoutRecord`'s Codable, so they carry the
  sidecar through. Not read in depth (see **Not confirmed**).

### Trade-off: sidecar on schema 2 versus schema 3

| | Sidecar on v2 (chosen, АР2) | Schema v3 |
|---|---|---|
| Older build reads the store | Every terminal restored, flattened into the focused pane | `.unreadable`: no layouts restored, no writes, reaper skipped |
| Session safety | Safe (all ids in the base) | Safe (reaper skipped) |
| Downgrade UX | Good | Bad until the store is reset |
| Upstream merges | No version collision | A future upstream v3 collides with the fork's v3 |
| In-memory = persisted | No: fold on write, unfold on read | Yes, with a new wire shape |
| Code | Fold/unfold + one record key | New `PaneLayout` wire format, migration, readers |
| Grouping after an old build writes | Lost (re-derived by rule) | Never written by an old build |

## Views

Mode is read from `LayoutFeature.State.mode` through the scoped layout store
(ДР2), never by aggregating content state in a parent.

1. `supacode/Features/Terminal/Views/WorktreeLayoutView.swift`: when
   `layoutStore.mode == .splitPerTab`, render
   `VStack(spacing: 0) { WorktreeGroupStripView(store: layoutStore, runtime: runtime, …); LayoutAlertHost(…) }`.
   v2 renders exactly as today. The empty-layout hint is unchanged (⌘T
   creates group 1).
2. New `supacode/Features/Terminal/Views/WorktreeGroupStripView.swift`:
   - The strip body reads only `store.layout.groupOrder`,
     `store.layout.activeGroupID` and `store.mode`; it lays out one
     `WorktreeGroupTabView(groupID:)` per id.
   - `WorktreeGroupTabView` resolves its group's focused pane's selected
     `TabItem` and reads that content's `TabChrome` (title via
     `TabTitle.resolved`, accessory, shimmer, progress, agent badge, unseen
     dot) itself, exactly like `PaneTabView`, so a chrome tick of one content
     invalidates one group tab, never the strip or siblings.
   - Click → `store.send(.selectGroup(id:))` plus
     `host.focusSelectedTab()` through the same path the strip uses today.
   - No close button and no close item in a context menu (ОП14): ⌘W or a
     pane's own close closes terminals one by one, and the group goes with
     its last pane. Tooltip on each group tab: its title and, for the first
     nine, "Select Tab N" with its `AppShortcuts.tabSelection` hotkey.
   - Drag to reorder → `.moveGroup(id:toIndex:)`.
   - Trailing accessories reuse `PaneTabStripAccessories`
     (`PaneTabStripView.swift` L854), changed from `private` to internal with
     its signature unchanged; they act on the
     focused pane: "+" sends `.newGroup` through `contentRequestedNewTab`
     (tooltip with `AppShortcuts.newTerminalTab`), split right / down, zoom,
     window mode. Every button has a tooltip with its hotkey.
   - Rename: double-click opens the inline rename of the group's focused
     content tab (`beginTabRename(id:)`), per ОП7.
   - System colours only, Dynamic Type, `.monospaced()` where the v2 strip
     uses it.
3. `Views/LayoutContentView.swift` `PaneStripView` (L319): when
   `store.mode == .splitPerTab` and `context == .embedded`, omit
   `PaneTabStrip` (the pane has one tab)
   and the tab-drag drop zones; keep the content toolbar, `ContentHostView`,
   dim overlay and hover-focus sensor. Read `store.mode` at this leaf.
4. `Views/PaneWindowManager.swift`: a windowed SPT pane (`context == .windowed`)
   KEEPS its one-tab `PaneTabStrip`. It carries the title, the inline rename
   editor (so Rename Tab from a pane window shows a field even when the main
   window shows another worktree) and the accessories. Window mode works per
   pane as in v2 (ОП11).
5. Rendering of parked groups: none. `LayoutPaneTreeView` renders
   `tree.visibleNode`, i.e. the active group only; parked panes are not in
   the view tree (v1's `TerminalTabContentStack` rendered only the selected
   tab too).
6. `WorktreeLayoutView.selectedContentID` (L83) changes on a group switch, so
   the existing `onChange` refocuses the terminal; no change needed.

## Menus and shortcuts

Menu closures capture only the store, so no `FocusedAction` token changes
(ДР9). The mode branch lives in the handlers.

| Command | v2 | SPT | Where |
|---|---|---|---|
| ⌘T New Terminal Tab | new tab in the focused pane | new group after the active one | reducer `newTab` SPT branch (no WTM change) |
| ⌘W | "Close Tab": closes the focused content tab | "Close Terminal": closes the focused pane (its only tab); the last pane closes the group | title in `WindowCommands`; behaviour unchanged in WTM (`closeFocusedTab` already closes the focused content tab) |
| ⌘1..9 Select Tab N | index in the focused pane's strip | index in the group strip | `WorktreeTerminalManager.selectTab(atIndex:in:)` |
| Select Next / Previous Tab | focused pane's strip | group strip, wrapping | `WorktreeTerminalManager.selectRelativeTab(forward:in:)` |
| Rename Tab | focused content tab | focused content tab of the active group (= the group's title, ОП7) | unchanged |
| Split / Focus Split / Zoom / Equalize / Window Mode | focused pane | focused pane of the active group | unchanged |

`selectTab(atIndex:in:)` in SPT: `layout.groupID(atIndex: index)` →
`focusedPaneID(ofGroup:)` → its selected tab; send `.wakeTab(id:)` then
`.selectGroup(id:)`. `selectRelativeTab` in SPT: `groupID(relativeToActive:)`,
same two sends. v2 branches are today's code.

`WindowCommands.swift`: title `settingsFile.global.terminalLayoutMode == .splitPerTab ? "Close Terminal" : "Close Tab"`.
Shortcut handling unchanged. In a pane window `PaneWindowShortcut.intent`
(`PaneWindowManager.swift` L49-110) stays window-local in SPT, by decision:
the window shows one pane, so ⌘1..9 select that pane's only tab and next /
previous are consumed no-ops (`pane.tabs.count > 1` fails); they never drive
the main window's group strip. ⌘T sends `newTab(contentID)` →
`contentRequestedNewTab` → a new group; ⌘W closes the pane; Rename Tab opens
the window's own strip editor. No code change in `intent`.

`AppFeature.selectTerminalTabAtIndex` (L1078) and the next / previous actions
are unchanged; they already route to these WTM handlers.

## CLI and deeplinks

The addressable vocabulary is unchanged: `tab` = content tab (a split leaf in
SPT), `surface` = content id, `pane` = pane. Group ids are never public (ДР3).

| Verb | SPT semantics | Code |
|---|---|---|
| `tab list` | every content tab of every group; entries gain `group` (ДР8); `focused=1` on the active group's focused tab | `WorktreeTerminalManager.listTabs` (L271) |
| `pane list` | every pane of every group; entries gain `group` and, for the active group, `activeGroup=1`; `focused=1` as today | `listPanes` (L1424) |
| `surface list` | unchanged (one content per tab) | `listSurfaces` (L285) |
| `tab focus`, `surface focus`, `pane focus` | switches to the owning group (through `focus()`) | unchanged WTM code |
| `tab new` (with or without `--pane`) | new group (АР4); the ack and `TabID == ContentID` invariant unchanged | reducer `newTab` branch; `createTabAsync` unchanged |
| `pane split` | split inside the token's group; a background split of a parked pane does not switch | reducer `modifyTree` |
| `tab close`, `surface close`, `pane close` | closes that pane / tab; the last pane closes the group; never closes other panes of the group | unchanged WTM code |
| `pane zoom`, `pane window` | the token's pane, in its own group; zooming a parked pane activates its group first | reducer (owning-tree rules) |
| `pane equalize` | the active group (the command takes no pane token) | `.equalizePanes`, unchanged |
| `tab move` | refused with an alert (АР5) | `canMoveTabToNewSplit` + AppFeature `.tabMove` |
| `tab rename` | renames the content tab (in SPT the group shows it when it is the group's focused tab, ОП7) | unchanged |

`WorktreeTerminalManager.canMoveTabToNewSplit` returns false when
`layoutState.mode == .splitPerTab` (explicitly, not only through the
one-tab-per-pane count). `AppFeature` `.tabMove` (L3060-3074) keeps the title
"Tab cannot be moved" and picks the message by the target layout's mode,
read from its own state as `state.terminals.layouts[id: worktreeID]?.mode`
(AppFeature already reads `state.terminals.layouts` this way at L2109 and
L2224; no new `TerminalClient` query):

- v2 (unchanged): "Its pane has only this tab, or is in window mode, so there is nothing to split off."
- SPT: "In Splits in Each Tab mode every tab is already its own split, so there is nothing to split off."

Deeplinks (`supacode/Domain/Deeplink.swift` L41-61) map to the same
handlers, so they inherit every row above; no new case.

## Sidebar and Recent Terminals

- Sidebar rows see only `WorktreeRowProjection`.
  `WorktreeContentHost.allSurfaceIDs` (L158) is `layout.allContentIDs`, which
  covers parked groups through the flat `panes`. Unseen counts, badges and
  `allTabsDormant` therefore include parked terminals. No change in
  `computeSidebarStructure`.
- `RecentTerminals.items` iterates all panes and tabs (flat) and keeps parked
  tabs. Pruning (`AppFeature` L2230) keeps every `panes.flatMap(\.tabs.ids)`,
  so parked history survives. `currentTabID` = the active group's focused
  pane's selected tab. A palette pick sends `.selectTab(id:)` (AppFeature
  L1735-1747), which switches group through `focus()`.
- `WindowTitle` (`supacode/App/WindowTitle.swift` L54-74) reads
  `host.focusedTab`, which is the active group's focused tab.

## Hibernation

No code change in `TerminalsFeature.reconcileHibernation`. Parked panes are
not in `tree.visibleLeaves()`, so their tabs are hidden: they arm the 5-minute
grace timer and hibernate, and `recencyRetains` (visible panes only) does not
cover them. That is v1's behaviour. Switching to a group makes its panes
visible; the re-diff after `selectGroup` (`canAffectVisibility` = true) wakes
them. A windowed pane of a parked group stays live (`paneShowsContent` is true
for windowed panes, L218). Hibernation keeps the zmx session; it never kills.

## Blocking scripts

`runBlockingScript` (WTM L1112-1194) creates a locked, ephemeral tab through
`newTab`, which in SPT creates a new group (v1: a script tab was top-level).
Host tracking is keyed by `TabID`, which conversions never change, so a
running script survives a mode switch. Persistence strips the script's pane
and, with it, its group (group-aware `strippingEphemeralContent`).

## Owner-settled behaviour

### Group title (ОП7)

A group has no title state of its own. It shows its focused pane's content
tab title (`TabTitle.resolved` over that tab and its `TabChrome`). Rename Tab
and the strip's inline rename set `customTitle` on that `TabItem`. Nothing new
is persisted and nothing is lost in a conversion. Consequence: moving focus
between splits of a group changes the group's title, as v1's window title
did.

### Switching back (ОП9)

Only the ВП2 lossy rule. SPT → v2 → SPT flattens every non-active group's
splits into one-pane groups; v2 → SPT → v2 brings background tabs back in
the focused pane. No "last SPT grouping" is remembered for the switch back.
The АР2 sidecar is written only while the layout is in SPT (it restores SPT
across a relaunch); a v2-mode write removes it (ДР11).

### Window mode in SPT (ОП11)

Allowed per pane, as in v2. `focus()` activates the group of a focused
windowed pane (ДР10). A windowed pane in a parked group keeps its window and
stays live. SPT → v2 exits window mode for every dissolved pane inside
`convertMode`; v2 → SPT keeps a windowed pane windowed (its id survives).
The Toggle Window Mode menu item and the CLI `pane window` are unchanged.

### No Close Group verb (ОП14)

No new menu item, shortcut, strip close button, context menu item, CLI verb
or deeplink. ⌘W ("Close Terminal" in SPT, ДР9) closes the focused pane, and
`tab close` / `surface close` / `pane close` close one pane. When the last
pane of a group closes, `collapse` removes the group (parked) or promotes the
neighbour (active, ДР5) through `removeLeaf` →
`promoteNeighbourOfEmptiedActiveGroup()`. That internal path is the only
group-closing code; it never reaps anything beyond the pane being closed.

## Risks

1. **Session-killing reads.** Any helper that enumerates only the active
   group would feed the reaper, `reconcileContentLifecycle` or Recent
   Terminals pruning an incomplete set. Mitigation: flat `panes` (АР1), and
   tests that assert parked contents in `allContentIDs`,
   `allKnownSurfaceIDs` and the projection.
2. **Closing is killing.** A conversion or group switch built from close and
   recreate kills sessions. Mitigation: `convertMode` and `activateGroup` are
   pure value transforms; a test with a `ContentSessionKiller` that records
   calls asserts zero kills across both conversions.
3. **Debug invariant trap.** The gate asserts inside one action; a writer who
   mutates `tree` before the group bookkeeping traps in DEBUG. Every SPT
   mutation finishes in one reducer turn.
4. **Focus fallback to `panes.first`.** In SPT that can be a parked pane, and
   `focus()` would switch groups by accident. Mitigation: collapse and
   stripping fall back to the active tree's first leaf.
5. **Exhaustive switches and the `default` in `canRemoveTabs`.** The compiler
   catches three of four. No new action removes tabs (there is no
   `closeGroup`, ОП14), so `canRemoveTabs` needs no new case; a future
   tab-removing action must be added by hand.
6. **`TerminalClient.Command` lists.** `setTerminalLayoutMode` must be in
   both WTM `return false` lists and handled once.
7. **Hydration order.** The reaper reads the persisted file, not the state,
   so converting at hydration is safe as long as the transform never drops a
   content (it cannot: pure, id-preserving).
8. **Remount flicker** on a mode switch. Accepted;
   `scheduleDeferredActivityReassert` re-asserts focus after a structural
   rebuild.
9. **Writer round-trip.** If the fold is not deterministic (for example, it
   iterates a `Set`), every flush rewrites the record. The fold iterates
   `groupOrder` and `tree.leaves()` only.
10. **Config hand-edits are not live.** `SettingsFilePersistence.subscribe`
    returns an empty `SharedSubscription` (L347-352), so editing
    `terminalLayoutMode` in `config.json` while the app runs triggers no
    `settingsChanged` and no conversion. The edit takes effect at the next
    launch, where hydration converts every stored layout to the mode it
    reads. No live reload path is added. Separately, `attachLayout` may read
    a new mode before
    `layoutModeChanged` arrives; `convertMode` is idempotent per layout, so
    the late conversion skips it.

## Tests

Use Swift Testing and TCA `TestStore`; drive time with `TestClock` and
`advance`; never `Task.sleep`; mint ids with `withDependencies { $0.uuid = .incrementing }`.
Every existing suite must pass unchanged with the default mode.

1. **Setting** (`SupacodeSettingsSharedTests` / `SettingsFeatureTests`):
   default is `.tabsPerSplit`; missing, unknown (`"grid"`) and non-string
   values decode to the default; round-trip of both values; `SettingsFeature`
   load / apply / write-back.
2. **Model** (`PaneLayoutTests` + new `SplitPerTabLayoutTests`):
   v2 → SPT on a 2-pane layout with 3 + 2 tabs gives 3 parked groups (4
   groups in all) in АР3
   order with ids from the incrementing sequence; ids, titles, `customTitle`
   and zoom preserved; SPT → v2 appends in group then leaf order and keeps the
   home selection; both conversions keep `allContentIDs` and the tab id set
   equal; `isConsistent` rejects each broken group invariant (1-6);
   `isSplitPerTabShape`; `activateGroup` swaps trees and focus and preserves
   per-group zoom; group-aware `strippingEphemeralContent` drops a script
   group and never focuses a parked pane; `wireFormatIsPinned` unchanged.
3. **Persistence** (`LayoutPersistenceTests`, `LayoutsIncrementalWriterTests`,
   `LayoutsMigratorTests`): fold of an SPT layout is `isConsistent` v2 and
   holds every content id; `fold(unfold(fold(x))) == fold(x)`, and unfold of
   a fold equals the live layout after canonical pane ordering (same trees,
   focus, zoom, group order, tab sets per pane); a duplicated parked group id
   and an unfold that fails `isConsistent(for: .splitPerTab)` both fall back;
   each unfold check (1-6) failing falls back to the v2 → SPT rule; a v2
   record encodes byte-identical to today (no `splitPerTab` key); a record
   with a sidecar decoded by `LayoutRecord` keeps it; an unreadable sidecar
   decodes the record and is not a decode loss; the writer replaces and
   removes the sidecar; a new pin test for the sidecar wire format;
   `allKnownSurfaceIDs` of a folded record includes parked contents.
4. **LayoutFeature** (`LayoutFeatureTests` stays green; new
   `LayoutFeatureSplitPerTabTests`): `convertMode` both ways with a recording
   `ContentSessionKiller` (zero kills) and no `ContentRuntime.remove`;
   idempotent `convertMode`; dissolved windowed pane leaves
   `windowedPaneIDs`; a pending alert on a dissolved pane is cancelled;
   `selectGroup`; `selectTab` / `contentRequestedFocus` of a parked tab switch
   group; `newTab` and `contentRequestedNewTab` create a group in ДР6
   position; `newGroup` on an empty layout bootstraps group 1; split of a
   parked pane with `select: false` keeps the active group; closing the last
   pane of a parked group removes the group; closing the active group's last
   pane activates the previous, else the next group; closing the last group
   empties the layout; ⌘W (`contentRequestedClose(.tab)`) on a group's only
   pane with each confirm mode closes that group; `moveGroup` clamps; refused `moveTab*` in SPT; `contentRequestedGotoTab`
   over groups; zoom stays per group across switches; `toggleZoom` on a
   parked pane activates its group and keeps every layout consistent, and
   with `preservesZoomOnNavigation = true` and the group's remembered zoom on
   P1, `toggleZoom(P2)` zooms P2 while `toggleZoom(P1)` clears the zoom;
   `enterWindowMode` on a zoomed pane of a parked group clears that group's
   zoom.
5. **TerminalsFeature** (`TerminalsFeatureTests`): two flips whose
   `layoutModeChanged` arrive out of order end in the current setting;
   `layoutModeChanged` sends
   one `convertMode` per layout including a hostless hydrated one (receive
   each) and fires `layoutChanged` per worktree; hydration in SPT with a valid
   sidecar, an invalid one, and none; hydration in v2 ignores a sidecar;
   `attachLayout` takes the setting's mode; hibernation: a parked group's tab
   arms the grace timer and hibernates after `clock.advance(by: .seconds(300))`,
   and `selectGroup` wakes it.
6. **Plumbing** (`AppFeatureSettingsTests` or the suite that covers
   `lastKnownTerminalHibernationEnabled`): a settings change sends
   `.setTerminalLayoutMode` once; no send when unchanged.
7. **Manager and CLI** (`WorktreeTerminalManagerAckTests`,
   `AppFeatureDeeplinkTests`, new SPT cases): anchored `tab new` in SPT
   creates a group and acks with `TabID == ContentID`; `listTabs` /
   `listPanes` carry `group` / `activeGroup` in SPT only; ⌘1..9 and next /
   previous select groups in SPT; `canMoveTabToNewSplit` false in SPT and the
   SPT alert text; `openFilePlacement` `.tab` lands as a new group in SPT;
   quit save writes a converted hostless layout with no debounce elapsed;
   `PaneWindowShortcutTests`: in SPT ⌘2 and next / previous in a pane window
   are window-local (no group switch).
8. **Recent Terminals** (`AppFeatureRecentTerminalsTests`): parked tabs are
   listed and not pruned; a pick of a parked tab switches group; the new
   actions' rows of the switch table.
9. **Views**: no snapshot tests exist for the strip; cover the view logic
   through the reducer and keep view bodies free of derived state.

Verification after implementation (not part of this spec task):

```sh
make test
make build-app
```

## Task split

Each task is independently reviewable. "Depends on" means it needs the other
task's types merged first; tasks without a dependency between them can run in
parallel. Test group numbers refer to **Tests**.

| Task | Files and symbols | Depends on | Tests |
|---|---|---|---|
| **T1 Setting** | `SupacodeSettingsShared/Models/GlobalSettings.swift` (`TerminalLayoutMode`, `terminalLayoutMode` field, init, `CodingKeys`, decode); `SupacodeSettingsFeature/Reducer/SettingsFeature.swift` (state, load, apply, write-back); `SupacodeSettingsFeature/Views/TerminalSettingsView.swift` (picker) | none | 1 |
| **T2 Model** | `supacode/Features/Terminal/Models/PaneLayout.swift`: `PaneGroupID`, `PaneGroup`, the three fields, new init, `encode` assert, `isConsistent`, `isSplitPerTabShape`, `isConsistent(for:)`, lookups, `activateGroup`, `modifyTree`, `removeLeaf`, both conversions, group-aware `strippingEphemeralContent`, `SplitPerTabSidecar`, `foldedForPersistence`, `unfolding` | T1 (`TerminalLayoutMode` for `isConsistent(for:)`; T1 is small, land it first) | 2, model part of 3 |
| **T3 Persistence** | `LayoutsMigrator.swift` (`LayoutRecord.splitPerTab`, `CodingKeys`, decode, init); `LayoutsIncrementalWriter.swift` (merge line); `LayoutPersistence.swift` (strip then fold) | T2 | 3 |
| **T4 Reducer** | `LayoutFeature.swift` (`State.mode`, gate predicate, four actions, `convertMode`, `focus`, `collapse`, `newGroup`, `moveGroup`, `modifyTree` call sites incl. `reduceEnterWindowMode` and `reduceToggleZoom`, SPT branches); the switch rows in `TerminalsFeature.canAffectVisibility` and `RecentTerminals.canChangeCurrentTab` / `canRemoveTabs` (same commit, or the build breaks) | T2 | 4, switch rows of 8 |
| **T5 TerminalsFeature** | `TerminalsFeature.swift` (`layoutModeChanged` reading the current setting, `attachLayout` mode, `layoutsHydrated` unfold / convert, `uuid` dependency) | T3, T4 | 5 |
| **T6 Plumbing** | `TerminalClient.swift` (`setTerminalLayoutMode`); `WorktreeTerminalManager.swift` (`handleSearchCommand` and `handleBindingActionCommand` `return false` lists, `handleManagementCommand`, `saveAllLayoutSnapshots` + `cancelPendingLayoutSaves` quit coverage); `AppFeature.swift` (`lastKnownTerminalLayoutMode` at L167 / L208 / L772 / L905); `supacodeApp.swift` `applicationWillTerminate` (capture order) | T1, T5 | 6, quit-save row of 7 |
| **T7 Manager semantics** | `WorktreeTerminalManager.swift` (`selectTab(atIndex:in:)`, `selectRelativeTab`, `listTabs`, `listPanes`, `canMoveTabToNewSplit`); `AppFeature.swift` `.tabMove` message | T4 (reads `LayoutFeature.State.mode`) | 7, 8 |
| **T8 Views** | new `WorktreeGroupStripView.swift`; `WorktreeLayoutView.swift`; `LayoutContentView.swift` `PaneStripView` (strip omitted only for `.embedded`); `PaneTabStripView.swift` (`PaneTabStripAccessories` `private` → internal); `PaneWindowManager.swift` (no code change expected; add the SPT rows to `PaneWindowShortcutTests`); `WindowCommands.swift` (⌘W title) | T4 | 9 (reducer-backed), pane-window shortcut rows |

T6 and T7 both edit `WorktreeTerminalManager.swift` and `AppFeature.swift`
in different functions; run them in sequence or rebase the second.

## Not confirmed

- serena reference search returns nothing without a sourcekit index, so
  reference lists come from `grep` (and the recon's graphify pass). Type uses
  through inference or extensions could be missed.
- `SidebarPersistenceMigrator` (L711-742) and `SettingsRelocationMigrator`
  (L182, L273) were not read; the claim that they carry the sidecar rests on
  their going through `LayoutRecord` Codable.
- The CLI has no JSON output mode that I found (`TabCommand` prints
  `ListFormatting.line`); the new `group` fields reach socket clients only.
- The jump-to-latest-unread call site in `AppFeature` was not read; the spec
  assumes it sends `.selectTab`, which switches group through `focus()`.
- `PaneTabStripView` accessory buttons (around L855-950) were only skimmed;
  T8 must confirm they can be reused outside a pane strip.

## Done when

- The setting exists, defaults to Tabs in Each Split, and survives a
  hand-edited `config.json` with any value (applied at the next launch).
- Switching modes converts every worktree (hosted or not) in place; no zmx
  session is killed; tab and content ids, scripts, Recent Terminals entries
  and sidebar badges survive.
- SPT shows one group strip per worktree, one split tree per group, per-group
  zoom; ⌘T, ⌘W, ⌘1..9 and next / previous follow the table.
- CLI and deeplinks behave as in the CLI table; `tab move` refuses in SPT with
  the SPT message.
- A relaunch restores the SPT grouping; an older build restores every
  terminal flattened and kills none.
- All existing tests pass unchanged; the new suites pass; `make build-app`
  succeeds.
