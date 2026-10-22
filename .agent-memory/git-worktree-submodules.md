---
name: git-worktree-submodules
description: Read before removing a git worktree of this repo, for example after an agent or captain run.
---

# Removing a worktree with submodules

The repo has submodules (`ThirdParty/ghostty`, `ThirdParty/zmx`, `Resources/git-wt`), so
`git worktree remove <path>` refuses with
`fatal: working trees containing submodules cannot be moved or removed`.

1. Check that `git -C <path> status -s` is empty and the branch is merged.
2. Copy anything you need out of the worktree first (for example `tmp/claude-logs/`).
3. Then run `git worktree remove --force <path>`.
