# agentctl-ios

AgentCtl makes an app agent-addressable: every screen describes itself (path, summary, error, commands), and a CLI
drives it headlessly on the Mac, or in the running app through a debug-only bridge. This is the Swift reference
implementation; see the README for the layout and commands.

## Standing rules

1. **Two ports, one product.** [agentctl-android](https://github.com/olbartek/agentctl-android) (locally
   `~/Developer/Projects/bartosz/agentctl-android`) is the Kotlin port. Every change lands in both repositories:
   the same features, the same CLI commands and options, the same example apps (TinyApp, AgentShop) with
   byte-identical scenario files, and the same MAJOR.MINOR version (see Releases). A difference only Kotlin or Android forces is recorded
   in the Android README's contract section.
2. **CONTRACT.md is the spec, and it lives here.** Change it here first, then copy it to the Android repo unchanged.
3. **Headless runs are deterministic.** Nothing in the engine reads real time, randomness or the locale; the only
   real-time reads are settling's safety limits.
4. **Scenario files are shared.** Edit `Examples/*/scenarios/*.appctl` here, then copy them to the Android repo's
   `examples/*/scenarios/`. The Android repo's AgentShop parity test compares its output with this repo's CLI
   (`examples/agentshop/bench/ios_transcripts.sh` there regenerates the transcripts).

## Releases

The two repositories share MAJOR.MINOR; PATCH is each repository's own.

- **MAJOR.MINOR is the lockstep promise:** the same CONTRACT.md, features, CLI commands and options, and scenario
  files. A minor or major release ships in both repositories together, even when one side changes nothing but its
  version.
- **PATCH is per repository,** for a fix no script or CLI user can see: a platform bug, a flaky test, a build
  problem. Android at 0.4.2 beside iOS at 0.4.1 is the same 0.4 product with one more fix on Android.
- **Every fix is checked against the other port.** Its PR says "ported to <repo>#<n>" or "not applicable: <why>".
  Each side whose shipped code changes bumps its own PATCH; a side that changes only tests or docs does not release.
- **A change to step output, the CLI's surface, CONTRACT.md or a scenario is never a patch.** It is a minor release
  of both repositories.

Tags are bare `X.Y.Z` on `main`. To release here: bump the README's version pins and Status, merge, then tag and push the
tag. For a minor or major release, release agentctl-android with the same number.

## After a merge

Clean up what the work used, once its PR is merged:

- Remove its worktree (`git worktree remove <path>`), then delete its branch (`git branch -D <branch>`: a squash
  merge leaves it unmerged in git's eyes).
- Delete that worktree's Xcode DerivedData folder: the `~/Library/Developer/Xcode/DerivedData/<Scheme>-<hash>` whose
  `info.plist` `WorkspacePath` is the worktree.
- Never remove a worktree with uncommitted changes, or one another session is using.
- The main checkout's `.build` and DerivedData stay.
