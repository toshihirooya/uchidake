#!/usr/bin/env bash
#
# CI でテストに使う iPhone シミュレータの UDID を出す。
#
#   scripts/ci_simulator.sh          # 例: 1A2B3C4D-...
#
# ランナーのイメージや Xcode の版が変わると、入っているシミュレータの機種名も変わる
# （"iPhone 16" が無くなる、など）。機種名を決め打ちせず、入っている中で最新の iOS の
# iPhone を選ぶ。CI_SIMULATOR_NAME で機種名を指定したときは、その名前のものを選ぶ。

set -euo pipefail

xcrun simctl list devices available --json | python3 -c '
import json, os, re, sys

want = os.environ.get("CI_SIMULATOR_NAME", "")
best = None
for runtime, devices in json.load(sys.stdin)["devices"].items():
    m = re.search(r"SimRuntime\.iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    version = (int(m.group(1)), int(m.group(2)))
    for d in devices:
        name = d["name"]
        if want and name != want:
            continue
        if not want and not name.startswith("iPhone"):
            continue
        if best is None or version > best[0]:
            best = (version, d["udid"], name)

if best is None:
    sys.exit("iPhone のシミュレータが見つからない" + (f"（{want}）" if want else ""))
print(f"選んだシミュレータ: {best[2]} (iOS {best[0][0]}.{best[0][1]})", file=sys.stderr)
print(best[1])
'
