#!/bin/sh
# Exports the failure screenshots and element trees of the latest UI test run to .bench/att, and lists them.
cd "$(dirname "$0")/.." || exit 1
R=$(ls -td .bench/DerivedData/Logs/Test/*.xcresult | head -1)
rm -rf .bench/att && mkdir -p .bench/att
xcrun xcresulttool export attachments --path "$R" --output-path .bench/att >/dev/null 2>&1
python3 - <<'PY'
import json
for t in json.load(open(".bench/att/manifest.json")):
    for a in t["attachments"]:
        if "at failure" in (a.get("suggestedHumanReadableName") or ""):
            print(t["testIdentifier"], ".bench/att/" + a["exportedFileName"])
PY
