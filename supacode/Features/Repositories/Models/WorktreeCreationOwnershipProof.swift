import Foundation

/// Proof, read from the `wt` / `git worktree add` output (forced to the C
/// locale), that this creation's own `git worktree add -b <branch>` completed:
/// git printed the new-branch preparing line and then checked the tree out. Git
/// refuses an existing branch, or a non-empty path, before it makes the worktree
/// (an existing path can leave the new branch behind), so without both lines the
/// directory at the target is not provably this creation's and is left in place.
/// A new-branch line without the checkout, and without git refusing the branch,
/// means git made this creation's branch and then failed (a failed checkout, or a
/// taken path); git removes its own half-made directory then, so only the branch
/// is this creation's to delete (`ownsBranchOnly`).
nonisolated struct WorktreeCreationOwnershipProof {
  let branchName: String
  private var sawNewBranch = false
  private var sawCheckout = false
  private var sawBranchRefusal = false

  init(branchName: String) {
    self.branchName = branchName
  }

  var provesOwnership: Bool { sawNewBranch && sawCheckout }

  var ownsBranchOnly: Bool { sawNewBranch && !sawCheckout && !sawBranchRefusal }

  mutating func record(_ line: String) {
    if line.contains("Preparing worktree (new branch '\(branchName)')") { sawNewBranch = true }
    if sawNewBranch, line.contains("HEAD is now at ") { sawCheckout = true }
    // Git could not create the branch: another creation holds it.
    if line.contains("a branch named '\(branchName)' already exists") || line.contains("cannot lock ref") {
      sawBranchRefusal = true
    }
  }
}
