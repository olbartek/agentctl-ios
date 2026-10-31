# The commands your CLI gets

| Command | What it does |
|---|---|
| `run "<script>"` | Run a script against a fresh headless app, one step per command. `--diff` adds a state diff per step, `--json` prints a JSON array of steps instead of text, and `--session <file>` replays a saved file first and then appends the commands that succeed, so state survives across calls (a file that does not exist yet is an empty session; one that cannot be read or written prints `error: cannot read <file>: <reason>` or `error: cannot write <file>: <reason>` and exits 3). |
| `state` | The full root state, `customDump`ed, after replaying an optional session file. |
| `screens` | Every screen path with its commands, arguments, help and summary keys — as above. |
| `docs` | Write the generated command reference (`docsPath`) from the registry. `--check` exits 1 when it is stale, which is what keeps it honest in CI. |
| `test [files…]` | Run `*.appctl` scenario files (by default all of `scenariosPath`), one PASS/FAIL line each. Finding no scenario files to run is a failure, not "0 passed". |
| `snapshots` | The view snapshot tests, on an iOS simulator; `--record` re-records the reference images. |
| `check` | The verification ladder below; `--ui` adds its last two rungs. |
| `app launch` / `app run` / `app state` / `app screens` | The same commands, against the real app on a simulator, through the in-app bridge. `app launch` takes port 8765, or the next free one if something else holds it, and records it in `<outputPath>/bridge.json` with the launch's token (mode 0600); the other `app` commands read it from there and send the token to the port it records. `--port` or `APPCTL_PORT` names one instead, and `APPCTL_TOKEN` a token. A bridge that refuses the token or the request exits 3. |
| `app screenshot <png>` / `app record start <mp4>` / `app record stop` / `app statusbar clean\|reset` / `app info` | The simulator itself, for demos: a screenshot; a recording that runs across other commands until `stop` (only the recorder `start` began is stopped); a 9:41 status bar with full signal and battery, or the simulator's own; the installed app's ID, version and build as one JSON line. Each acts on `--sim`, else the last launch's simulator (`bridge.json`), else the config's. |
| `app permission grant\|revoke\|reset <service>` / `app openurl <url>` / `app push <payload.json>` / `app location <lat>,<lon>\|clear` / `app appearance light\|dark` | The real OS on the simulator (`simctl privacy`, `openurl`, `push`, `location`, `ui appearance`), for demos and real-OS checks; a script simulates the device with `device` instead. Each acts on `--sim`, else the last launch's simulator, else the config's. |
| `app test [files…]` | The scenario files, in the real app on a simulator: one fresh launch each, one PASS/FAIL/SKIP line each. `--record <mp4>` records the run, `--step-delay <s>` sends a line at a time so the recording can be followed. |

Exit codes are part of the contract: `0` everything ran and every `expect` passed; `1` a command or an `expect`
failed, or a step — `(launch)` included — did not settle; `2` a usage or parse error, the CLI's own command line
included, and a command group run without a subcommand (`<cli>` or `<cli> app` alone prints its help on stderr;
`--help` prints it on stdout and exits 0); `3` an internal or environment error — a scenario file that does not
exist, no scenario files to run, no repo root, a build that failed, a `--session` file that cannot be read or
written. `snapshots` and `check` exit 1 only when something ran and found the app wrong (a rung that failed,
snapshots that differ), 2 for an ambiguous `--sim`, and 3 when they could not run (no simulator for the runtime,
a tool that could not start, a failed launch, an unreachable bridge); see
[the verification ladder](verification-ladder.md#exit-codes).

Four runtime commands work on every screen: `expect k=v [k=v …]`, `advance <duration>` (the virtual clock
headlessly; in the running app, the app's real-time clock jumped forward, see [the bridge](bridge.md)),
`mock <client.method> <error>`, and `wait [<duration>] [k=v …]`, which waits (10 s unless told otherwise) until the
pairs match or, with none, until the screen's line changes — headlessly by moving the clock to each timer due, in the
running app in real time (CONTRACT.md §2.5). An app that simulates its device has a fifth, `device …`
([the device environment](device-environment.md)).

Headless runs are deterministic by construction, so the same script always prints the same bytes — which is what
makes step output usable as a committed fixture. `HeadlessHost` runs everything on one serial executor and pins
exactly these dependencies of your store:

| Dependency | Headless value |
|---|---|
| `\.continuousClock` | a `TestClock` that only `advance` moves (counting its sleeps for `pending=`) |
| `\.uuid` | `.incrementing` |
| `\.date` | 2026-01-01T09:00:00Z, on every read |
| `\.withRandomNumberGenerator` | a SplitMix64 generator with a fixed seed |
| `\.timeZone`, `\.locale`, `\.calendar` | UTC, `en_US_POSIX`, and the Gregorian calendar in UTC |
| `\.mockLatency` | zero |
| `\.mockCallLog`, `\.mockFaults` | fresh for every run |

**Nothing else is pinned.** If your app uses `\.mainQueue`, `\.suspendingClock` or any other source of time, pin
it yourself in the closure you pass `HeadlessHost` — it runs after the table above, so it can override any of
it too — and give your mock backends fresh state there. Anything read around the dependency system (a formatter
built on `Locale.current`, say) is not pinned at all.
