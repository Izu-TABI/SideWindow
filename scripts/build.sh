#!/usr/bin/env bash
# SideWindow.app をビルドする
#
# 使い方:
#   ./scripts/build.sh            build/SideWindow.app を作る
#   ./scripts/build.sh --run      ビルドして起動する
#   ./scripts/build.sh --install  /Applications にインストールして起動する
#   ./scripts/build.sh --universal  Apple シリコンと Intel の両方で動く版を作る（配布用）
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="SideWindow"
APP="build/$APP_NAME.app"

INSTALL=false
RUN=false
UNIVERSAL=false
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=true; RUN=true ;;
    --run) RUN=true ;;
    --universal) UNIVERSAL=true ;;
    *) echo "不明なオプション: $arg" >&2; exit 1 ;;
  esac
done

if [[ ! -f Resources/AppIcon.icns ]]; then
  echo "▸ アイコンを生成"
  swift scripts/make-icon.swift Resources/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if $UNIVERSAL; then
  # Xcode なしでも作れるよう、アーキテクチャごとにビルドして lipo でまとめる
  BINARIES=()
  for ARCH in arm64 x86_64; do
    echo "▸ コンパイル (release, $ARCH)"
    TRIPLE="$ARCH-apple-macosx15.2"
    swift build -c release --triple "$TRIPLE"
    BINARIES+=("$(swift build -c release --triple "$TRIPLE" --show-bin-path)/$APP_NAME")
  done
  lipo -create -output "$APP/Contents/MacOS/$APP_NAME" "${BINARIES[@]}"
else
  echo "▸ コンパイル (release)"
  swift build -c release
  cp "$(swift build -c release --show-bin-path)/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
fi

echo "▸ $APP を組み立て"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 日本語・英語の両方に対応していることを macOS に伝える（標準のボタンや「このアプリについて」も英語になる）
cp -R Resources/*.lproj "$APP/Contents/Resources/"

echo "▸ 署名 (ad-hoc)"
codesign --force --sign - "$APP"

if $RUN; then
  pkill -x "$APP_NAME" 2>/dev/null && sleep 0.5 || true
fi

if $INSTALL; then
  echo "▸ /Applications にインストール"
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  APP="/Applications/$APP_NAME.app"
fi

if $RUN; then
  open "$APP"
fi

echo "✓ $APP"
