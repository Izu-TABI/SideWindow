#!/usr/bin/env bash
# 実際のパネルを使った動作確認（移動・リサイズ・拡大・最小化・自動で隠す など）
#
# 使い方: ./scripts/selftest.sh [スクリーンショットの保存先] [アプリに渡す引数…]
#   英語の画面で確かめる: ./scripts/selftest.sh build/selftest-en -AppleLanguages "(en)"
# テスト用のウィンドウが数十秒表示される。自分のウィンドウを取り込むので画面収録の許可は不要
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-build/selftest}"
shift || true
rm -rf "$OUT"
mkdir -p "$OUT"

swift build
.build/debug/SideWindow --selftest "$OUT" "$@" &
PID=$!
# 固まったときのために 150 秒で打ち切る
( sleep 150; kill "$PID" 2>/dev/null ) &
WATCHDOG=$!
STATUS=0
wait "$PID" || STATUS=$?
kill "$WATCHDOG" 2>/dev/null || true
echo "スクリーンショット: $OUT"
exit "$STATUS"
