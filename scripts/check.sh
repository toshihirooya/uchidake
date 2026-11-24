#!/usr/bin/env bash
#
# PR を出す前の確認。CI（.github/workflows/ci.yml）と同じことを手元で行う。
#
#   scripts/check.sh            # iOS のビルド＋単体テストと、サイトの確認
#   scripts/check.sh --ios      # iOS だけ
#   scripts/check.sh --site     # サイトだけ
#
# develop 向けの PR では CI の iOS ジョブが動かないので、PR を作る前にこれを通す。
# シミュレータは scripts/ci_simulator.sh が選ぶ（CI_SIMULATOR_NAME で機種名を指定できる）。
# テスト結果は build/check/Uchidake.xcresult に残る（Xcode で開ける）。

set -euo pipefail

cd "$(dirname "$0")/.."

RUN_IOS=1
RUN_SITE=1
for arg in "$@"; do
  case "$arg" in
    --ios) RUN_SITE=0 ;;
    --site) RUN_IOS=0 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "不明な引数: $arg" >&2; exit 2 ;;
  esac
done

OUT=build/check
SPM="$OUT/spm"
RESULT="$OUT/Uchidake.xcresult"

# 手元の Mac に古い visionOS ランタイムが重なっていると出る objc の警告を消す（結果には関係ない）
hide_objc_noise() { grep -v '^objc\[\|One of the duplicates' || true; }

check_site() {
  echo "== サイトの確認"
  python3 -c "import json; json.load(open('firebase.json'))"
  echo "  firebase.json: OK"
  # App Store のメタデータ（fastlane/metadata/*/privacy_url.txt）が指しているページ
  for f in site/index.html site/privacy.html site/en/index.html site/en/privacy.html; do
    if [ -f "$f" ]; then echo "  $f: OK"; else echo "  $f がない" >&2; exit 1; fi
  done
}

check_ios() {
  echo "== SPM の依存を解決"
  mkdir -p "$OUT"
  # Package.resolved と食い違うときは、黙って別の版に解決せず失敗させる
  xcodebuild -resolvePackageDependencies \
    -project Uchidake.xcodeproj \
    -scheme Uchidake \
    -clonedSourcePackagesDirPath "$SPM" \
    -onlyUsePackageVersionsFromResolvedFile \
    -quiet 2>&1 | hide_objc_noise

  echo "== シミュレータを用意"
  local udid
  udid="$(scripts/ci_simulator.sh 2>"$OUT/simulator.log")" || { cat "$OUT/simulator.log" >&2; exit 1; }
  grep '選んだ' "$OUT/simulator.log" | sed 's/^/  /'
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1

  echo "== ビルド＋単体テスト"
  rm -rf "$RESULT"
  local status
  set +e
  xcodebuild test \
    -project Uchidake.xcodeproj \
    -scheme Uchidake \
    -destination "id=$udid" \
    -parallel-testing-enabled NO \
    -clonedSourcePackagesDirPath "$SPM" \
    -onlyUsePackageVersionsFromResolvedFile \
    -resultBundlePath "$RESULT" \
    -quiet 2>&1 | hide_objc_noise
  status=${PIPESTATUS[0]}
  set -e

  # 件数をまとめて出す（-quiet だと成功時に何も出ないため）
  if [ -d "$RESULT" ]; then
    xcrun xcresulttool get test-results summary --path "$RESULT" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
g = d.get
print("  結果: %s  全 %s 件 / 成功 %s / 失敗 %s / スキップ %s" % (
    g("result"), g("totalTestCount"), g("passedTests"), g("failedTests"), g("skippedTests")))
for f in g("testFailures", []):
    print("  ✗ %s: %s" % (f.get("testIdentifierString") or f.get("testName"), f.get("failureText", "")))
' || true
  fi
  if [ "$status" -ne 0 ]; then
    echo "  テスト失敗（詳細: open $RESULT）" >&2
    exit "$status"
  fi
}

if [ "$RUN_SITE" = 1 ]; then check_site; fi
if [ "$RUN_IOS" = 1 ]; then check_ios; fi
echo "== すべて OK"
