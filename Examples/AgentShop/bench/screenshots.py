#!/usr/bin/env python3
"""Takes the screenshots in docs/APP.md: drives the real app on a simulator to each screen through the agent bridge,
then saves what the simulator shows.

    python3 bench/screenshots.py
    python3 bench/screenshots.py --only shop-feed,cart

Writes docs/screenshots/<name>.png, scaled down to 600 px high. Needs the app built for testing, which
`bench/bench.py` does; this script builds it too if needed.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bench  # noqa: E402

SHOTS = bench.ROOT / "docs/screenshots"

ALICE = "email alice@example.com\npassword Passw0rd!\nsubmit\n"
NINA = "email nina@example.com\npassword Passw0rd!\nsubmit\n"

# Each screenshot is the screen a script ends on, from a fresh launch with no saved session.
SCREENS: list[tuple[str, str]] = [
    ("login", "email alice@example.com\npassword Passw0rd!\n"),
    ("otp-code", "email alice@example.com\nuse-otp\nsend\n"),
    ("register", "register\nname Nina Park\nemail new@example.com\n"),
    ("onboarding-welcome", NINA),
    ("onboarding-interests", NINA + "skip\ntoggle bags\ntoggle home\n"),
    ("onboarding-address", NINA + "skip\ntoggle bags\ntoggle home\ncontinue\nname Nina Park\nstreet 2 Elm St\ncity Portland\n"),
    ("shop-feed", ALICE),
    ("shop-feed-filtered", ALICE + "filter shoes\nsort price-desc\n"),
    ("product", ALICE + "open 101\nsize 42\nqty-up\n"),
    ("cart", ALICE + "open 101\nsize 42\nadd-to-cart\nview-cart\npromo-code SAVE10\napply-promo\n"),
    ("checkout", ALICE + "open 101\nsize 42\nadd-to-cart\nview-cart\ncheckout\nshipping express\ncard 4242 4242 4242 4242\n"),
    ("confirmation", ALICE + "open 101\nsize 42\nadd-to-cart\nview-cart\ncheckout\ncard 4242 4242 4242 4242\nplace-order\n"),
    ("orders", ALICE + "tab orders\n"),
    ("profile", ALICE + "tab profile\n"),
]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--only", default="")
    parser.add_argument("--sim", default="iPhone 17 Pro")
    parser.add_argument("--port", type=int, default=8799)
    args = parser.parse_args()
    only = {s for s in args.only.split(",") if s}

    udid, runtime = bench.resolve_simulator(args.sim)
    print(f"screenshots on {args.sim} ({runtime})", flush=True)
    bench.run(["xcrun", "simctl", "boot", udid], check=False)
    bench.run(["xcrun", "simctl", "bootstatus", udid, "-b"])
    # A clean status bar: 9:41, full battery and signal.
    bench.run(["xcrun", "simctl", "status_bar", udid, "override", "--time", "9:41", "--batteryState", "charged",
               "--batteryLevel", "100", "--cellularBars", "4", "--wifiBars", "3"], check=False)
    bench.run(["swift", "build", "--product", "shopctl"])
    if not list((bench.DERIVED / "Build/Products").glob("*.xctestrun")):
        bench.build_for_testing(udid)
    bench.install_app(udid)
    SHOTS.mkdir(parents=True, exist_ok=True)

    for name, script in SCREENS:
        if only and name not in only:
            continue
        bench.cli("app", "launch", "--no-build", "--clear-session", "--latency", "0", "--sim", udid, "--port", str(args.port))
        _, output, code = bench.cli("app", "run", "--port", str(args.port), script, check=False)
        if code != 0:
            print(output[-1500:])
            sys.exit(f"screenshots: {name} did not get to its screen")
        time.sleep(0.8)  # animations
        path = SHOTS / f"{name}.png"
        bench.run(["xcrun", "simctl", "io", udid, "screenshot", "--type=png", str(path)])
        bench.run(["sips", "-Z", "600", str(path)])
        print(f"  {path.relative_to(bench.ROOT)}", flush=True)

    bench.run(["xcrun", "simctl", "status_bar", udid, "clear"], check=False)


if __name__ == "__main__":
    main()
