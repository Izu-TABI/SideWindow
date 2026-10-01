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

# ソーシャルプレビューに使うので、先にアイコンを作っておく
swift scripts/make-icon.swift --preview "$OUT/icon-1024.png" >/dev/null

# 日本語版（hero.png・zoom.png）と英語版（hero-en.png・zoom-en.png）を撮る
STATUS=0
for LANGUAGE in ja en; do
  echo "▸ $LANGUAGE"
  .build/debug/SideWindow --demo "$OUT" -AppleLanguages "($LANGUAGE)" &
  PID=$!
  ( sleep 120; kill "$PID" 2>/dev/null ) &
  WATCHDOG=$!
  wait "$PID" || STATUS=$?
  kill "$WATCHDOG" 2>/dev/null || true
done

# README で見やすく、ファイルも重くなりすぎない大きさにする
for NAME in hero hero-en; do sips -Z 1800 "$OUT/$NAME.png" >/dev/null; done
for NAME in zoom zoom-en; do sips -Z 2000 "$OUT/$NAME.png" >/dev/null; done

echo "▸ アイコン"
sips -Z 256 "$OUT/icon-1024.png" --out "$OUT/icon.png" >/dev/null
rm "$OUT/icon-1024.png"
ls -la "$OUT"
exit "$STATUS"
