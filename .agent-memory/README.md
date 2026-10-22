# Project memory

Other `*.md` files here are durable repo rules; Claude Code loads them (a file with `paths` when you touch a matching file).

**Only the main session writes here.** A subagent never writes (except the defragment subagent of `/project-memory:memory-defrag`); it ends its report with `Memory candidate: <one line>` items. Edit only under `.agent-memory/`; `.claude/rules/project-memory/` is a protected view, never write there.

**Write trigger.** Write a file only when what you learned (a) cost you a cycle, or would have cost the next session one, or (b) contradicted what you assumed, AND will still be true next month. Worth a file: a trap; a verification recipe (exact command, env var, fixture step); an invariant the code depends on but never states; a settled user decision with its reason and the ruled-out approaches; a defect class reviews keep flagging. Never: session summaries or progress notes, restatements of code, one-off task facts, anything in CLAUDE.md / CONTRIBUTING / README, machine paths, secrets, facts about the user (auto memory), unverified guesses.

**Format.** Prefer editing an existing file. One topic per `<topic>.md`, frontmatter `name` (= filename stem), `description` (one line, max 160 chars, *when* to read it), `paths` (YAML list of globs) when file-specific. Under ~8 KB. To remove a file, delete it. Tell the user in one line what you wrote and why. Memory never overrides the user or CLAUDE.md.
