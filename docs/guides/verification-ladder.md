# The verification ladder

`check` runs the cheapest checks first and stops at the first failure, printing one line per rung:

| Rung | What runs |
|---|---|
| L0 | `swift build` for each package path in `packages` |
| L1 | `swift test` for each of those that has a `Tests` directory |
| L2 | every scenario file, in-process |
| docs | `docs --check`: the generated command reference is not stale |
| L3 (`--ui`) | the `*SnapshotTests` of each package path in `snapshotPackages`, on an iOS simulator |
| L4 (`--ui`) | the real app: built, launched seeded on a simulator, one scenario sent through the bridge, one screenshot |

The rule that makes this pay off: **verify at the cheapest rung that proves the change.** Logic and flows are
L1/L2 and take milliseconds; only a view change needs L3, and only the app shell, the bridge or navigation needs
L4. Everything the CLI writes goes under the config's `outputPath`, `.appctl/` by default: `logs/`,
`screenshots/`, `snapshot-failures/`, and `DerivedData/` for builds without XcodeBuildMCP. Keep it out of version
control.

**AgentCtl assumes no repository layout.** It finds the root by walking up from the working directory for the
config's `rootMarker` (your `.xcworkspace` or `.xcodeproj` unless you name another file), and every other path
comes from the config, relative to that root:

- `packages` and `snapshotPackages` are package paths, such as `Packages/Features/Auth`, or `.` for a package at
  the root. A package is named by its path's last component in reports and log file names. That is also its
  SwiftPM identity, so it is unique within one build graph.
- L0 and L1 run `swift build` / `swift test --package-path <path>` for each path in `packages`, and L1 runs only
  where `<path>/Tests` exists.
- L3 runs `xcodebuild test` inside `<path>` for each path in `snapshotPackages`, with `-only-testing:` for each
  of its `Tests/*SnapshotTests` directories. The scheme is the one `xcodebuild -list` names after the directory:
  `<name>`, or `<name>-Package` for a package with several products (a package with a single scheme uses it,
  whatever its name). Reference images live in `<path>/Tests/<Target>SnapshotTests/__Snapshots__/`, recorded on
  `snapshotSimulatorName` at `snapshotRuntimeMajor` (a reference image only compares on the device and iOS
  version it was recorded on). It drives recording and artifact collection through
  [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing)'s
  `TEST_RUNNER_SNAPSHOT_TESTING_RECORD` and `TEST_RUNNER_SNAPSHOT_ARTIFACTS`.
- L4 needs a real Xcode `target` and `bundleID`, and takes its seed, its scenario and the screen the app must
  end on from the config's `appCheck`.

- `scenariosPath`, `docsPath` and `outputPath` default to `scenarios`, `docs/agent-commands.md` and `.appctl`.

The example app in this repository shows the headless end of this: TinyApp is a target of the package at the
root, so its config lists `packages: ["."]`, and `swift run tinyctl check` builds and tests this whole package,
runs TinyApp's scenarios and checks its docs. It has no Xcode project, so `app`, `snapshots` and `check --ui`
cannot work there; they are the parts of the CLI this repository does not exercise end to end.
