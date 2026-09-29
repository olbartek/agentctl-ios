# agentctl-ios

AgentCtl makes an app agent-addressable: every screen describes itself (path, summary, error, commands), and a CLI
drives it headlessly on the Mac, or in the running app through a debug-only bridge. This is the Swift reference
implementation; see the README for the layout and commands.

## Standing rules

1. **Two ports, one product.** [agentctl-android](https://github.com/olbartek/agentctl-android) (locally
   `~/Developer/Projects/bartosz/agentctl-android`) is the Kotlin port. Every change lands in both repositories:
   the same features, the same CLI commands and options, the same example apps (TinyApp, AgentShop) with
   byte-identical scenario files, and the same version number. A difference only Kotlin or Android forces is recorded
   in the Android README's contract section.
2. **CONTRACT.md is the spec, and it lives here.** Change it here first, then copy it to the Android repo unchanged.
3. **Headless runs are deterministic.** Nothing in the engine reads real time, randomness or the locale; the only
   real-time reads are settling's safety limits.
4. **Scenario files are shared.** Edit `Examples/*/scenarios/*.appctl` here, then copy them to the Android repo's
   `examples/*/scenarios/`. The Android repo's AgentShop parity test compares its output with this repo's CLI
   (`examples/agentshop/bench/ios_transcripts.sh` there regenerates the transcripts).

## Releases

Both repositories release together, with the same version and the same tag format: a bare `X.Y.Z` tag on `main`
(`0.4.1`). Bump the README's version pins and Status, tag, push the tag, then release the Android port with the same
number.
