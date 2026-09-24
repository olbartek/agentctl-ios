#!/usr/bin/env python3
"""Times AgentShop's scenarios in three modes and writes a report.

    python3 bench/bench.py                       # everything, 3 headless runs per scenario
    python3 bench/bench.py --quick               # 1 run each, for a smoke test of the script itself
    python3 bench/bench.py --groups auth --modes headless,bridge
    python3 bench/bench.py --dry-run             # print what would run

The three modes run the *same* scenario files (`scenarios/<group>-*.appctl`):

- headless: `shopctl test <file>` on the Mac: no simulator, no views, a virtual clock.
- bridge:   the real app on a simulator, driven through AgentCtlBridge: `shopctl app launch` (a fresh app, no
            session, no mock latency), then `shopctl app run "<the file>"`.
- uitest:   the XCUITests `bench/gen_uitests.py` generates from the same files, run by `xcodebuild
            test-without-building`, one class per group, not in parallel.

Only scenarios that can run in all three modes are compared (see `bench/uitests.json`); the others, which move
time with `advance` or restart with `reset`, are timed headlessly and listed separately.

A fourth measurement is the loop an agent actually runs: change one line of a reducer, then verify it — headlessly
(`swift build` of the CLI + one scenario) versus through the UI (`xcodebuild build-for-testing` + that scenario's
UI test).

Writes docs/benchmarks/<date>-agentshop.md in the repository, and the raw numbers to .bench/<timestamp>.json.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import platform
import re
import shlex
import statistics
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPO = ROOT.parent.parent
OUT = ROOT / ".bench"
DERIVED = OUT / "DerivedData"
CLI = ROOT / ".build/debug/shopctl"
MANIFEST = ROOT / "bench/uitests.json"
REPORT_DIR = REPO / "docs/benchmarks"
GROUPS = {"auth": "AuthUITests", "onboarding": "OnboardingUITests", "shop": "ShopUITests"}
GROUP_TITLES = {"auth": "Authentication", "onboarding": "Onboarding", "shop": "Shop"}
#: The reducer the change loop edits, and a line in it that the edit appends a comment to.
CHANGE_FILE = ROOT / "Sources/ShopFeature/ShopFeed.swift"
CHANGE_ANCHOR = "      case let .filterTapped(filter):\n        state.filter = filter\n"
CHANGE_SCENARIO = "shop-filter-category"

DRY_RUN = False


def log(message: str) -> None:
    print(message, flush=True)


def run(command: list[str], *, check: bool = True, env: dict | None = None, timeout: float | None = None) -> tuple[float, str, int]:
    """Runs a command in the example's root; returns (seconds, stdout+stderr, exit code)."""
    if DRY_RUN:
        log("  $ " + shlex.join(command))
        return 0.0, "", 0
    start = time.perf_counter()
    proc = subprocess.run(
        command, cwd=ROOT, capture_output=True, text=True, env=env, timeout=timeout
    )
    seconds = time.perf_counter() - start
    output = proc.stdout + proc.stderr
    if check and proc.returncode != 0:
        sys.exit(f"bench: command failed ({proc.returncode}): {shlex.join(command)}\n{output[-4000:]}")
    return seconds, output, proc.returncode


def cli(*arguments: str, check: bool = True) -> tuple[float, str, int]:
    import os

    env = dict(os.environ, APPCTL_ROOT=str(ROOT))
    return run([str(CLI), *arguments], check=check, env=env)


# MARK: Setup


def resolve_simulator(name: str) -> tuple[str, str]:
    """The simulator `shopctl app launch --sim <name>` picks: booted first, then released runtimes, then newest."""
    devices = json.loads(subprocess.run(["xcrun", "simctl", "list", "devices", "available", "-j"], capture_output=True, text=True).stdout)["devices"]
    runtimes = json.loads(subprocess.run(["xcrun", "simctl", "list", "runtimes", "-j"], capture_output=True, text=True).stdout)["runtimes"]
    beta = {r["identifier"] for r in runtimes if r.get("buildversion", "")[-1:].islower()}
    candidates = []
    for runtime, entries in devices.items():
        if "iOS" not in runtime:
            continue
        version = tuple(int(x) for x in runtime.split(".")[-1].split("-")[1:])
        for device in entries:
            if device["name"] == name:
                key = (device["state"] == "Booted", runtime not in beta, version)
                candidates.append((key, device["udid"], "iOS " + ".".join(map(str, version))))
    if not candidates:
        sys.exit(f"bench: no simulator named {name}")
    _, udid, runtime = max(candidates)
    return udid, runtime


def xctestrun() -> Path:
    files = sorted((DERIVED / "Build/Products").glob("*.xctestrun"), key=lambda p: p.stat().st_mtime)
    if not files:
        sys.exit("bench: no .xctestrun after build-for-testing")
    return files[-1]


def build_for_testing(udid: str) -> tuple[float, str]:
    seconds, output, _ = run([
        "xcodebuild", "build-for-testing", "-project", "App/AgentShop.xcodeproj", "-scheme", "AgentShop",
        "-destination", f"id={udid}", "-derivedDataPath", str(DERIVED), "-skipMacroValidation", "-quiet",
    ])
    return seconds, output


def install_app(udid: str) -> None:
    app = DERIVED / "Build/Products/Debug-iphonesimulator/AgentShop.app"
    run(["xcrun", "simctl", "install", udid, str(app)])


# MARK: Measurements


def median(values: list[float]) -> float:
    return statistics.median(values) if values else 0.0


def measure_headless(scenarios: list[str], runs: int) -> dict:
    """Per scenario: wall time of `shopctl test <file>` (process start included) and the in-process time it prints."""
    results = {}
    for name in scenarios:
        walls, inside = [], []
        steps = 0
        for _ in range(runs):
            seconds, output, code = cli("test", f"scenarios/{name}.appctl", check=False)
            if code != 0:
                results[name] = {"passed": False, "output": output[-2000:]}
                break
            walls.append(seconds)
            match = re.search(r"\((\d+) steps, (\d+) ms\)", output)
            if match:
                steps = int(match.group(1))
                inside.append(int(match.group(2)) / 1000)
        else:
            results[name] = {"passed": True, "wall_s": median(walls), "in_process_s": median(inside), "steps": steps}
        log(f"  headless {name}: {results[name].get('wall_s', 0) * 1000:.0f} ms"
            + ("" if results[name]["passed"] else "  FAIL"))
    return results


def measure_headless_group(files: list[str], runs: int) -> float:
    """One `shopctl test` process running a whole group: what an agent runs to check everything at once."""
    walls = [cli("test", *[f"scenarios/{f}.appctl" for f in files], check=False)[0] for _ in range(runs)]
    return median(walls)


def measure_bridge(scenarios: list[str], udid: str, port: int) -> dict:
    """Per scenario: a fresh launch of the installed app (until its bridge answers), then the scenario through it."""
    results = {}
    for name in scenarios:
        script = (ROOT / f"scenarios/{name}.appctl").read_text()
        launch_s, launch_out, launch_code = cli(
            "app", "launch", "--no-build", "--clear-session", "--latency", "0", "--sim", udid, "--port", str(port),
            check=False,
        )
        if launch_code != 0:
            results[name] = {"passed": False, "launch_s": launch_s, "run_s": 0.0, "output": launch_out[-2000:]}
            log(f"  bridge {name}: launch FAILED")
            continue
        run_s, run_out, run_code = cli("app", "run", "--port", str(port), script, check=False)
        results[name] = {"passed": run_code == 0, "launch_s": launch_s, "run_s": run_s}
        if run_code != 0:
            results[name]["output"] = run_out[-2000:]
        log(f"  bridge {name}: launch {launch_s:.1f} s + run {run_s:.2f} s" + ("" if run_code == 0 else "  FAIL"))
    return results


TEST_CASE = re.compile(r"Test Case '-\[AgentShopUITests\.(\w+) (\w+)\]' (passed|failed) \((\d+\.\d+) seconds\)")


def measure_uitests(group: str, udid: str, only: list[str] | None = None) -> tuple[float, dict, str]:
    """One group's UI tests (or a few of them) in one `xcodebuild test-without-building`, not in parallel."""
    targets = only or [f"AgentShopUITests/{GROUPS[group]}"]
    command = [
        "xcodebuild", "test-without-building", "-xctestrun", str(xctestrun()), "-destination", f"id={udid}",
        "-parallel-testing-enabled", "NO", "-resultBundlePath", str(OUT / f"results-{group}-{int(time.time())}.xcresult"),
    ] + [f"-only-testing:{t}" for t in targets]
    seconds, output, _ = run(command, check=False, timeout=7200)
    tests = {}
    for class_name, test, status, duration in TEST_CASE.findall(output):
        tests[f"{class_name}/{test}"] = {"passed": status == "passed", "seconds": float(duration)}
    return seconds, tests, output


# MARK: The change loop


class Change:
    """Appends a comment to one line of a reducer (a new one every time), and restores the file."""

    def __init__(self) -> None:
        self.original = CHANGE_FILE.read_text()
        if CHANGE_ANCHOR not in self.original:
            sys.exit(f"bench: {CHANGE_FILE.name} no longer contains the change anchor; update CHANGE_ANCHOR")
        self.count = 0

    def apply(self) -> None:
        self.count += 1
        changed = CHANGE_ANCHOR.replace("state.filter = filter\n", f"state.filter = filter  // bench {self.count}\n")
        CHANGE_FILE.write_text(self.original.replace(CHANGE_ANCHOR, changed, 1))

    def restore(self) -> None:
        CHANGE_FILE.write_text(self.original)


def measure_change_loop(udid: str, runs: int, uitest: str) -> dict:
    change = Change()
    headless, ui = [], []
    try:
        for _ in range(runs):
            change.apply()
            build_s, _, _ = run(["swift", "build", "--product", "shopctl"])
            test_s, _, _ = cli("test", f"scenarios/{CHANGE_SCENARIO}.appctl")
            headless.append(build_s + test_s)
            log(f"  change → headless: build {build_s:.1f} s + scenario {test_s * 1000:.0f} ms")

            change.apply()
            build_s, _ = build_for_testing(udid)
            test_s, tests, _ = measure_uitests("shop", udid, only=[uitest])
            ui.append(build_s + test_s)
            log(f"  change → UI test: build-for-testing {build_s:.1f} s + test {test_s:.1f} s")
    finally:
        change.restore()
    return {"headless_s": median(headless), "uitest_s": median(ui), "runs": runs}


# MARK: Report


def machine() -> dict:
    def out(command: list[str]) -> str:
        return subprocess.run(command, capture_output=True, text=True).stdout.strip()

    return {
        "cpu": out(["sysctl", "-n", "machdep.cpu.brand_string"]),
        "cores": out(["sysctl", "-n", "hw.ncpu"]),
        "macos": platform.mac_ver()[0],
        "xcode": " ".join(out(["xcodebuild", "-version"]).splitlines()),
        "swift": out(["swift", "--version"]).splitlines()[0] if out(["swift", "--version"]) else "",
    }


def fmt_s(seconds: float) -> str:
    if seconds < 1:
        return f"{seconds * 1000:.0f} ms"
    if seconds < 120:
        return f"{seconds:.1f} s"
    whole = round(seconds)
    return f"{whole // 60} min {whole % 60} s"


def ratio(slow: float, fast: float) -> str:
    return f"{slow / fast:,.0f}×" if fast > 0 and slow > 0 else "—"


def write_report(data: dict) -> Path:
    now = dt.datetime.now()
    info = data["machine"]
    manifest = data["manifest"]
    lines = [
        f"# AgentShop benchmark: headless vs simulator vs XCUITest ({now:%Y-%m-%d})",
        "",
        "Generated by `python3 Examples/AgentShop/bench/bench.py`. Every row runs the **same scenario file** in each",
        "mode: the headless CLI, the real app on a simulator driven through AgentCtlBridge, and an XCUITest generated",
        "from the scenario (`bench/gen_uitests.py`), which taps and types through the real UI.",
        "",
        f"- **Machine:** {info['cpu']}, {info['cores']} cores, macOS {info['macos']}",
        f"- **Tools:** {info['xcode']}; {info['swift']}",
        f"- **Simulator:** {data['simulator']}",
        f"- **Runs:** headless {data['runs']}× per scenario (median); bridge and UI tests once each.",
        "- **Settings:** both simulator modes launch a fresh app with no saved session and no mock latency, so the"
        " numbers compare the harnesses, not the fake backend.",
        "",
    ]

    groups = data["groups"]
    total = {"n": 0, "steps": 0, "headless": 0.0, "headless_group": 0.0, "bridge": 0.0, "bridge_run": 0.0, "ui_wall": 0.0, "ui_tests": 0.0}
    rows = []
    for group, g in groups.items():
        names = g["scenarios"]
        head = g.get("headless", {})
        bridge = g.get("bridge", {})
        ui = g.get("uitest", {})
        steps = sum(manifest[n]["steps"] for n in names)
        h = sum(head[n]["wall_s"] for n in names if head.get(n, {}).get("passed"))
        b = sum(bridge[n]["launch_s"] + bridge[n]["run_s"] for n in names if n in bridge)
        br = sum(bridge[n]["run_s"] for n in names if n in bridge)
        uw = ui.get("wall_s", 0.0)
        ut = sum(t["seconds"] for t in ui.get("tests", {}).values())
        for key, value in (("n", len(names)), ("steps", steps), ("headless", h), ("headless_group", g.get("headless_group_s", 0.0)),
                           ("bridge", b), ("bridge_run", br), ("ui_wall", uw), ("ui_tests", ut)):
            total[key] += value
        rows.append((GROUP_TITLES[group], len(names), steps, g.get("headless_group_s", 0.0), h, b, br, uw))
    rows.append(("**All**", total["n"], total["steps"], total["headless_group"], total["headless"], total["bridge"], total["bridge_run"], total["ui_wall"]))

    n, hg, bw, ui = total["n"], total["headless_group"], total["bridge"], total["ui_wall"]
    steps = max(total["steps"], 1)
    lines += [
        "## Summary",
        "",
        f"- **{n} scenarios, {total['steps']} steps, three ways.** Headless: **{fmt_s(hg)}**. The real app on a simulator,"
        f" through the bridge: **{fmt_s(bw)}**. The generated XCUITests: **{fmt_s(ui)}**.",
        f"- The UI tests take **{ratio(ui, hg)}** as long as the headless run, and **{ratio(ui, bw)}** as long as the"
        " same scenarios driven through the bridge on the same simulator.",
    ]
    if "change" in data:
        c = data["change"]
        lines.append(
            f"- After a one-line change to a reducer, verifying it headlessly (build + scenario) takes **{fmt_s(c['headless_s'])}**;"
            f" through a UI test, **{fmt_s(c['uitest_s'])}** ({ratio(c['uitest_s'], c['headless_s'])})."
        )
    lines += [
        "- Headless runs no simulator and renders no views, so it checks the app's logic and navigation, not pixels. The bridge"
        " checks the same things in the real app on a device, and the XCUITests check that the UI shows and reaches them.",
        "  The three are complementary; the point is which one an agent should run hundreds of times a day.",
        "",
        "## The three modes",
        "",
        "| Mode | What runs | How a step is sent | What it proves | Needs |",
        "|---|---|---|---|---|",
        "| **Headless** (`./appctl test`) | The features' reducers and the mocked clients, in a Mac process | A command, straight to the"
        " screen's store | Logic, navigation, errors, calls made, values the screen would show | `swift build` only |",
        "| **Simulator bridge** (`./appctl app run`) | The real app on a simulator, views and all | A command over the app's"
        " DEBUG-only HTTP bridge, then a 250 ms quiet wait | The same, in the real app process, with real views rendered |"
        " A simulator and a debug build |",
        "| **XCUITest** (generated) | The real app on a simulator, driven from a test runner app | A tap or typing on an"
        " accessibility element, then waits for what the screen shows | That the UI can reach every state: elements exist,"
        " are on screen and are tappable | A simulator, `build-for-testing`, a test runner |",
        "",
        "## Results",
        "",
        "### All modes, all scenarios",
        "",
        "| Mode | Total | Per scenario | Per step | vs XCUITest |",
        "|---|---|---|---|---|",
    ]
    for label, value in (
        ("Headless, one process for everything", hg),
        ("Headless, one process per scenario", total["headless"]),
        ("Simulator bridge, relaunch + run", bw),
        ("Simulator bridge, run only", total["bridge_run"]),
        ("XCUITest", ui),
    ):
        lines.append(f"| {label} | **{fmt_s(value)}** | {fmt_s(value / max(n, 1))} | {fmt_s(value / steps)} | {ratio(ui, value) + ' faster' if value and value != ui else '—'} |")
    lines += [
        "",
        "### Per group",
        "",
        "| Group | Scenarios | Steps | Headless, one process | Headless, one process per scenario | Simulator bridge (launch + run) | XCUITest | XCUITest vs headless |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for title, gn, gsteps, ghg, gh, gb, gbr, guw in rows:
        lines.append(
            f"| {title} | {gn} | {gsteps} | **{fmt_s(ghg)}** | {fmt_s(gh)} | {fmt_s(gb)} ({fmt_s(gbr)} running) | **{fmt_s(guw)}** | {ratio(guw, ghg)} |"
        )
    lines += [
        "",
        "- *Headless, one process* is `shopctl test` over the whole group: how an agent (or CI) checks everything.",
        "- *One process per scenario* adds a process start (~20–40 ms) to every scenario.",
        "- *Simulator bridge* relaunches the app for every scenario, as a UI test does; *running* is the scenario alone.",
        "- *XCUITest* is the wall time of `xcodebuild test-without-building` for the group (already built).",
        "",
    ]

    if "change" in data:
        c = data["change"]
        lines += [
            "### The loop an agent runs: change a line, verify it",
            "",
            f"A one-line change to the `ShopFeed` reducer, then `{CHANGE_SCENARIO}` verified (median of {c['runs']}).",
            "",
            "| | Time |",
            "|---|---|",
            f"| Headless: `swift build` of the CLI + the scenario | **{fmt_s(c['headless_s'])}** |",
            f"| UI test: `xcodebuild build-for-testing` + the scenario's UI test | **{fmt_s(c['uitest_s'])}** |",
            f"| Ratio | {ratio(c['uitest_s'], c['headless_s'])} |",
            "",
        ]

    if data.get("setup"):
        s = data["setup"]
        lines += ["### One-off costs", "", "| | Time |", "|---|---|"]
        for label, key in (("`swift build` of the CLI (warm)", "cli_build_s"), ("`xcodebuild build-for-testing` (warm)", "build_for_testing_s")):
            if key in s:
                lines.append(f"| {label} | {fmt_s(s[key])} |")
        lines.append("")

    checked = sum(manifest[n].get("assertions_checked_in_ui", 0) for g in groups.values() for n in g["scenarios"])
    headless_only_asserts = sum(manifest[n].get("assertions_headless_only", 0) for g in groups.values() for n in g["scenarios"])
    lines += [
        "## What the UI tests check",
        "",
        f"The generated UI tests assert {checked} of the scenarios' {checked + headless_only_asserts} expectations through the UI"
        " (screens, errors, shown values, enabled buttons). The other"
        f" {headless_only_asserts} — `loading=`, `call=`, `pending=`, values no screen shows — are checked headlessly only.",
        "",
    ]

    only = data.get("headless_only", {})
    if only:
        lines += [
            "## Headless-only scenarios",
            "",
            "These move a virtual clock (`advance`) or relaunch (`reset`), which a UI test can only do by really waiting"
            " or relaunching. Headlessly they take milliseconds:",
            "",
            "| Scenario | Steps | Headless | Real time a UI test would wait |",
            "|---|---|---|---|",
        ]
        for name, r in only.items():
            wait = r.get("advance_s", 0)
            lines.append(f"| `{name}` | {r.get('steps', 0)} | {fmt_s(r.get('wall_s', 0))} | {fmt_s(wait) if wait else '—'} |")
        lines.append("")

    lines += ["## Every scenario", ""]
    for group, g in groups.items():
        lines += [
            f"<details><summary>{GROUP_TITLES[group]} ({len(g['scenarios'])} scenarios)</summary>",
            "",
            "| Scenario | Steps | Headless (in-process) | Headless (with process start) | Bridge launch | Bridge run | XCUITest |",
            "|---|---|---|---|---|---|---|",
        ]
        tests = g.get("uitest", {}).get("tests", {})
        for name in g["scenarios"]:
            h = g.get("headless", {}).get(name, {})
            b = g.get("bridge", {}).get(name, {})
            test_id = manifest[name].get("uitest", "").removeprefix("AgentShopUITests/")
            t = tests.get(test_id, {})
            fail = lambda r: "" if not r or r.get("passed") else " ✗"
            lines.append(
                f"| `{name}` | {manifest[name]['steps']} | {fmt_s(h.get('in_process_s', 0))}{fail(h)} | {fmt_s(h.get('wall_s', 0))} | "
                f"{fmt_s(b.get('launch_s', 0)) if b else '—'} | {fmt_s(b.get('run_s', 0)) if b else '—'}{fail(b)} | "
                f"{fmt_s(t.get('seconds', 0)) if t else '—'}{fail(t)} |"
            )
        lines += ["", "</details>", ""]

    failures = [
        f"{mode} {name}"
        for g in groups.values()
        for mode in ("headless", "bridge")
        for name, r in g.get(mode, {}).items()
        if not r.get("passed")
    ] + [f"uitest {t}" for g in groups.values() for t, r in g.get("uitest", {}).get("tests", {}).items() if not r["passed"]]
    lines += [
        "## Caveats",
        "",
        "- One machine, one session. The ratios are more stable than the absolute numbers.",
        "- The bridge settles each step with a 250 ms quiet window, which dominates its per-step time.",
        "- UI tests run one at a time on one simulator; parallel clones would cut the wall time but not the per-test cost.",
        "- The UI tests had to work around what every UI suite hits: the system \"Save Password?\" sheet, the keyboard"
        " covering buttons, and password autofill fighting typed text (`-ui-testing` turns autofill hints off).",
        f"- Failures in this run: {', '.join(failures) if failures else 'none'}.",
        "",
    ]
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    path = REPORT_DIR / f"{now:%Y-%m-%d}-agentshop.md"
    path.write_text("\n".join(lines))
    return path


def advance_seconds(text: str) -> float:
    total = 0.0
    for amount, unit in re.findall(r"^advance (\d+)(ms|s|m|h)\s*$", text, flags=re.M):
        total += int(amount) * {"ms": 0.001, "s": 1, "m": 60, "h": 3600}[unit]
    return total


def main() -> None:
    global DRY_RUN
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--runs", type=int, default=3, help="headless runs per scenario (median)")
    parser.add_argument("--quick", action="store_true", help="one run of everything")
    parser.add_argument("--groups", default="auth,onboarding,shop")
    parser.add_argument("--modes", default="headless,bridge,uitest")
    parser.add_argument("--sim", default="iPhone 17 Pro")
    parser.add_argument("--port", type=int, default=8799, help="the bridge port (8765 is often taken by adb)")
    parser.add_argument("--no-change-loop", action="store_true", help="skip the change-a-line loop")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--report", metavar="RAW_JSON", help="only rewrite the report from a saved .bench/<timestamp>.json")
    args = parser.parse_args()
    if args.report:
        log(f"wrote {write_report(json.loads(Path(args.report).read_text())).relative_to(REPO)}")
        return
    DRY_RUN = args.dry_run
    runs = 1 if args.quick else args.runs
    groups = [g for g in args.groups.split(",") if g]
    modes = set(args.modes.split(","))

    manifest = json.loads(MANIFEST.read_text())["scenarios"]
    udid, runtime = resolve_simulator(args.sim)
    data: dict = {"machine": machine(), "simulator": f"{args.sim} ({runtime}, {udid})", "runs": runs,
                  "manifest": manifest, "groups": {}, "setup": {}}
    log(f"bench: {', '.join(groups)} in {', '.join(sorted(modes))} on {args.sim} ({runtime})")

    log("setup")
    run(["xcrun", "simctl", "boot", udid], check=False)
    run(["xcrun", "simctl", "bootstatus", udid, "-b"])
    run(["swift", "build", "--product", "shopctl"])
    data["setup"]["cli_build_s"] = run(["swift", "build", "--product", "shopctl"])[0]
    if modes & {"bridge", "uitest"} or not args.no_change_loop:
        build_for_testing(udid)
        data["setup"]["build_for_testing_s"] = build_for_testing(udid)[0]
        install_app(udid)

    for group in groups:
        names = sorted(n for n, m in manifest.items() if m["group"] == group and m["comparable"])
        g: dict = {"scenarios": names}
        log(f"{GROUP_TITLES[group]}: {len(names)} scenarios")
        if "headless" in modes:
            g["headless"] = measure_headless(names, runs)
            g["headless_group_s"] = measure_headless_group(names, runs)
            log(f"  headless group: {fmt_s(g['headless_group_s'])}")
        if "bridge" in modes:
            g["bridge"] = measure_bridge(names, udid, args.port)
        if "uitest" in modes:
            wall, tests, _ = measure_uitests(group, udid)
            g["uitest"] = {"wall_s": wall, "tests": tests}
            log(f"  UI tests: {fmt_s(wall)}, {sum(t['passed'] for t in tests.values())}/{len(tests)} passed")
        data["groups"][group] = g

    if "headless" in modes:
        only = sorted(n for n, m in manifest.items() if not m["comparable"] and m["group"] in groups)
        results = measure_headless(only, runs)
        for name in only:
            results[name]["advance_s"] = advance_seconds((ROOT / f"scenarios/{name}.appctl").read_text())
            results[name].setdefault("steps", manifest[name]["steps"])
        data["headless_only"] = results

    if not args.no_change_loop and "shop" in groups:
        log("change loop")
        uitest = manifest[CHANGE_SCENARIO]["uitest"]
        data["change"] = measure_change_loop(udid, runs, uitest)

    if DRY_RUN:
        return
    OUT.mkdir(parents=True, exist_ok=True)
    raw = OUT / f"{dt.datetime.now():%Y%m%d-%H%M%S}.json"
    raw.write_text(json.dumps(data, indent=2, default=str))
    report = write_report(data)
    log(f"wrote {report.relative_to(REPO)} (raw: {raw.relative_to(ROOT)})")


if __name__ == "__main__":
    main()
