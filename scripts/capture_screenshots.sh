#!/bin/zsh
# App Store 用のスクリーンショットをシミュレータで撮る。fastlane/screenshots/<言語>/ に出る。
#
#   scripts/capture_screenshots.sh            # 日本語と英語、iPhone 6.9 インチ（iPad は DEVICES="iPad Pro 13-inch (M5)" WAIT=15。窓の大きさが崩れることがあるので確かめる）
#   LANGS="ja" DEVICES="iPhone 17 Pro Max" scripts/capture_screenshots.sh
#
# 見る側の画面には、別のシミュレータ（HELPER）をカメラ役にして映像を流す。シミュレータにはカメラが無いので、
# 映像は色の変わるテスト画像になる（docs/spec.md の8章）。IMAGE=<写真のパス> を付けると、その写真を映像として送る。
# デバッグビルドの起動オプション（docs/spec.md の9章）を使う。
set -euo pipefail

ROOT=${0:A:h:h}
BUNDLE=com.toshihirooya.uchidake
OUT=$ROOT/fastlane/screenshots
DD=$ROOT/build/screenshots-dd
LANGS=(${=LANGS:-ja en-US})
DEVICES=("${(@s/,/)DEVICES:-iPhone 17 Pro Max}")
HELPER=${HELPER:-iPhone 17}
WAIT=${WAIT:-8}
IMAGE=${IMAGE:-}

udid() {
  xcrun simctl list devices available -j 2>/dev/null | python3 -c '
import json, sys
name = sys.argv[1]
for runtime, devs in sorted(json.load(sys.stdin)["devices"].items(), reverse=True):
    if "iOS" not in runtime: continue
    for d in devs:
        if d["name"] == name:
            print(d["udid"]); sys.exit(0)
sys.exit("no simulator: " + name)' "$1"
}

boot() {
  xcrun simctl boot "$1" 2>/dev/null || true
  xcrun simctl bootstatus "$1" -b >/dev/null
  xcrun simctl status_bar "$1" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
}

fresh_install() {
  xcrun simctl terminate "$1" $BUNDLE 2>/dev/null || true
  xcrun simctl uninstall "$1" $BUNDLE 2>/dev/null || true
  # 鍵はキーチェーンにあり、アプリを消しても残るので消す
  xcrun simctl keychain "$1" reset >/dev/null 2>&1 || true
  xcrun simctl install "$1" "$APP"
  xcrun simctl privacy "$1" grant all $BUNDLE 2>/dev/null || true
}

# 言語の起動オプション（ja → ja / ja_JP、en-US → en / en_US）
lang_args() {
  case $1 in
    ja) echo "-AppleLanguages (ja) -AppleLocale ja_JP" ;;
    *)  echo "-AppleLanguages (en) -AppleLocale en_US" ;;
  esac
}

launch() {
  local dev=$1; shift
  xcrun simctl terminate "$dev" $BUNDLE 2>/dev/null || true
  local image=()
  [[ -n $IMAGE ]] && image=(-screenshotImage "${IMAGE:A}")
  # 文字の大きさは標準にそろえる（シミュレータ側の設定は変えない）
  xcrun simctl launch "$dev" $BUNDLE "$@" -screenshots YES $image \
    -UIPreferredContentSizeCategoryName UICTContentSizeCategoryL >/dev/null
}

shot() {
  sleep $WAIT
  xcrun simctl io "$1" screenshot --type=png "$2" >/dev/null 2>&1
  echo "  $2:t"
}

echo "ビルドしています…"
xcodebuild -project "$ROOT/Uchidake.xcodeproj" -scheme Uchidake -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD" build -quiet
APP=$DD/Build/Products/Debug-iphonesimulator/Uchidake.app

KEY=$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=')
HELPER_ID=$(udid "$HELPER")
boot "$HELPER_ID"
fresh_install "$HELPER_ID"

for lang in $LANGS; do
  mkdir -p "$OUT/$lang"
  la=(${=$(lang_args $lang)})
  if [[ $lang == ja ]]; then name=子ども部屋; else name=Nursery; fi
  for device in $DEVICES; do
    id=$(udid "$device")
    prefix=${device// /_}
    echo "$lang / $device"
    boot "$id"

    # 1. 見ている画面（HELPER がカメラ）
    fresh_install "$id"
    launch "$HELPER_ID" $la -autoKey "$KEY" -autoRole camera -autoName "$name" -autoPlan family
    sleep 3
    launch "$id" $la -autoKey "$KEY" -autoRole viewer -autoPlan family
    shot "$id" "$OUT/$lang/${prefix}-1-viewer.png"

    # 2. カメラの画面（HELPER が見る側）
    launch "$id" $la -autoKey "$KEY" -autoRole camera -autoName "$name" -autoPlan family
    sleep 3
    launch "$HELPER_ID" $la -autoKey "$KEY" -autoRole viewer -autoPlan family
    shot "$id" "$OUT/$lang/${prefix}-2-camera.png"
    xcrun simctl terminate "$HELPER_ID" $BUNDLE 2>/dev/null || true

    # 3. 最初の画面（設定済み）
    fresh_install "$id"
    launch "$id" $la -autoKey "$KEY"
    shot "$id" "$OUT/$lang/${prefix}-3-home.png"

    # 4. はじめての設定（QR コードで端末をつなぐ）
    fresh_install "$id"
    launch "$id" $la
    shot "$id" "$OUT/$lang/${prefix}-4-setup.png"

    xcrun simctl terminate "$id" $BUNDLE 2>/dev/null || true
  done
done
xcrun simctl terminate "$HELPER_ID" $BUNDLE 2>/dev/null || true
echo "できました: $OUT"
