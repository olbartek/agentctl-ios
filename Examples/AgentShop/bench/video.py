#!/usr/bin/env python3
"""Records the same scenarios as an XCUITest run and through the simulator bridge, times them headlessly, and
composes the three side by side into one video with running timers.

    python3 bench/video.py
    python3 bench/video.py --scenarios auth-login-happy-path,shop-checkout-happy-path
    python3 bench/video.py --caption "…"      # the line under the panels (default: the latest bench.py totals)

Writes .bench/video/agentshop-three-modes.mp4 (and the two raw recordings next to it). Needs the app built for
testing, which `bench/bench.py` does; this script builds it too if needed.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bench  # noqa: E402

ROOT = bench.ROOT
VIDEO = bench.OUT / "video"
DEFAULT_SCENARIOS = ["auth-login-happy-path", "onboarding-address-prefills-checkout", "shop-checkout-happy-path"]


class Recorder:
    """`simctl io recordVideo` in the background. `started` is when it reported that recording had begun."""

    def __init__(self, udid: str, path: Path) -> None:
        self.path = path
        self.process = subprocess.Popen(
            ["xcrun", "simctl", "io", udid, "recordVideo", "--codec=h264", "--force", str(path)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        self.ready = threading.Event()
        self.started = 0.0
        threading.Thread(target=self._watch, daemon=True).start()
        if not self.ready.wait(20):
            self.process.kill()
            sys.exit("video: simctl recordVideo did not start")

    def _watch(self) -> None:
        for line in self.process.stdout:  # type: ignore[union-attr]
            if "Recording started" in line and not self.ready.is_set():
                self.started = time.perf_counter()
                self.ready.set()

    def stop(self) -> None:
        self.process.send_signal(signal.SIGINT)
        self.process.wait(30)


def headless(scenarios: list[str]) -> tuple[float, str]:
    files = [f"scenarios/{name}.appctl" for name in scenarios]
    seconds, output, _ = bench.cli("test", *files, check=False)
    text = "$ ./appctl test " + " ".join(f"{name}.appctl" for name in scenarios) + "\n" + output
    return seconds, text


def bridge(scenarios: list[str], udid: str, port: int) -> tuple[Path, float, float]:
    path = VIDEO / "bridge.mp4"
    # The app on screen before recording, so the recording starts on it rather than on the home screen.
    bench.cli("app", "launch", "--no-build", "--clear-session", "--latency", "0", "--sim", udid, "--port", str(port))
    time.sleep(1)
    recorder = Recorder(udid, path)
    time.sleep(0.5)
    start = time.perf_counter()
    for name in scenarios:
        script = (ROOT / f"scenarios/{name}.appctl").read_text()
        bench.cli("app", "launch", "--no-build", "--clear-session", "--latency", "0", "--sim", udid, "--port", str(port))
        _, output, code = bench.cli("app", "run", "--port", str(port), script, check=False)
        if code != 0:
            print(output[-2000:])
            sys.exit(f"video: {name} failed through the bridge")
    seconds = time.perf_counter() - start
    time.sleep(1)
    recorder.stop()
    return path, start - recorder.started, seconds


def uitests(scenarios: list[str], udid: str, manifest: dict) -> tuple[Path, float, float]:
    path = VIDEO / "uitest.mp4"
    recorder = Recorder(udid, path)
    time.sleep(0.5)
    start = time.perf_counter()
    tests = [manifest[name]["uitest"] for name in scenarios]
    command = [
        "xcodebuild", "test-without-building", "-xctestrun", str(bench.xctestrun()), "-destination", f"id={udid}",
        "-parallel-testing-enabled", "NO",
    ] + [f"-only-testing:{test}" for test in tests]
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    seconds = time.perf_counter() - start
    time.sleep(1)
    recorder.stop()
    if result.returncode != 0:
        print((result.stdout + result.stderr)[-3000:])
        sys.exit("video: the UI tests failed")
    return path, start - recorder.started, seconds


def default_caption() -> str:
    runs = sorted(bench.OUT.glob("2*.json"))
    if not runs:
        return "The same scenario files in all three modes."
    data = json.loads(runs[-1].read_text())
    groups = data.get("groups", {})
    n = sum(len(g["scenarios"]) for g in groups.values())
    h = sum(g.get("headless_group_s", 0) for g in groups.values())
    b = sum(r["launch_s"] + r["run_s"] for g in groups.values() for r in g.get("bridge", {}).values())
    u = sum(g.get("uitest", {}).get("wall_s", 0) for g in groups.values())
    if not (h and b and u):
        return "The same scenario files in all three modes."
    return f"All {n} scenarios: XCUITest {bench.fmt_s(u)} · simulator bridge {bench.fmt_s(b)} · headless {bench.fmt_s(h)}"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--scenarios", default=",".join(DEFAULT_SCENARIOS))
    parser.add_argument("--sim", default="iPhone 17 Pro")
    parser.add_argument("--port", type=int, default=8799)
    parser.add_argument("--caption")
    args = parser.parse_args()
    scenarios = [s for s in args.scenarios.split(",") if s]
    manifest = json.loads(bench.MANIFEST.read_text())["scenarios"]
    for name in scenarios:
        if not manifest.get(name, {}).get("comparable"):
            sys.exit(f"video: {name} is not a scenario that runs in all three modes")

    VIDEO.mkdir(parents=True, exist_ok=True)
    udid, runtime = bench.resolve_simulator(args.sim)
    print(f"video: {', '.join(scenarios)} on {args.sim} ({runtime})", flush=True)
    bench.run(["xcrun", "simctl", "boot", udid], check=False)
    bench.run(["xcrun", "simctl", "bootstatus", udid, "-b"])
    bench.run(["swift", "build", "--product", "shopctl"])
    if not list((bench.DERIVED / "Build/Products").glob("*.xctestrun")):
        bench.build_for_testing(udid)
    bench.install_app(udid)

    headless_s, headless_text = headless(scenarios)
    (VIDEO / "headless.txt").write_text(headless_text)
    print(f"  headless: {bench.fmt_s(headless_s)}", flush=True)
    bridge_path, bridge_start, bridge_s = bridge(scenarios, udid, args.port)
    print(f"  bridge: {bench.fmt_s(bridge_s)}", flush=True)
    ui_path, ui_start, ui_s = uitests(scenarios, udid, manifest)
    print(f"  XCUITest: {bench.fmt_s(ui_s)}", flush=True)

    out = VIDEO / "agentshop-three-modes.mp4"
    subprocess.run([
        "swift", str(ROOT / "bench/compose.swift"),
        "--uitest", str(ui_path), "--uitest-start", f"{ui_start:.3f}", "--uitest-seconds", f"{ui_s:.3f}",
        "--bridge", str(bridge_path), "--bridge-start", f"{bridge_start:.3f}", "--bridge-seconds", f"{bridge_s:.3f}",
        "--headless", str(VIDEO / "headless.txt"), "--headless-seconds", f"{headless_s:.3f}",
        "--caption", args.caption or default_caption(),
        "--out", str(out),
    ], check=True, cwd=ROOT, env=dict(os.environ))
    print(f"video: {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
