---
name: serena-swift-references
description: Read before using serena find_referencing_symbols on Swift here: it returns {} without a build index; use grep.
---

# serena reference search returns nothing for Swift in this repo

`find_referencing_symbols` returns `{}` for Swift types and methods here (checked on `PaneLayout`,
`LayoutFeature`, `ContentRuntime.claimRenderHost`), because sourcekit-lsp has no index store without a
build. `get_symbols_overview` and `find_symbol` work. Overloaded names need an index suffix
(`PaneLayout[0]` = the struct).

For "who uses type X": `command grep -rlE '\bX\b' --include='*.swift' supacode supacodeTests` (exclude
`.claude/worktrees/`). Say in the report that references came from grep.
</content>
