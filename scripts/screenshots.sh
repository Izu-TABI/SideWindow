#!/usr/bin/env bash
# README の画像（docs/images）を作り直す
#
# 架空の資料とレポートのウィンドウを並べて実際に固定し、自分のウィンドウだけを撮って合成する。
# 画面全体は撮らないので、ほかのアプリや個人の情報は写らない（画面収録の許可も不要）
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="docs/images"
mkdir -p "$OUT"

swift build
.build/debug/SideWindow --demo "$OUT" &
PID=$!
( sleep 60; kill "$PID" 2>/dev/null ) &
WATCHDOG=$!
STATUS=0
wait "$PID" || STATUS=$?
kill "$WATCHDOG" 2>/dev/null || true

# README で見やすく、ファイルも重くなりすぎない大きさにする
sips -Z 1800 "$OUT/hero.png" >/dev/null
sips -Z 2000 "$OUT/zoom.png" >/dev/null

echo "▸ アイコン"
swift scripts/make-icon.swift --preview "$OUT/icon-1024.png" >/dev/null
sips -Z 256 "$OUT/icon-1024.png" --out "$OUT/icon.png" >/dev/null
rm "$OUT/icon-1024.png"
ls -la "$OUT"
exit "$STATUS"
