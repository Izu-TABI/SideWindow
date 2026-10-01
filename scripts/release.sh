#!/usr/bin/env bash
# GitHub Releases にアプリを公開する
#
# 使い方:
#   ./scripts/release.sh
#
# Resources/Info.plist の CFBundleShortVersionString を v<バージョン> のタグにして、
# ユニバーサル版の SideWindow.zip を添付したリリースを作る。
# 新しいバージョンを出すときは、先に Info.plist のバージョンを上げてコミット・push しておく。
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="SideWindow"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
TAG="v$VERSION"
ZIP="build/$APP_NAME.zip"

# 公開するのはコミット・push 済みの状態だけにする
if [[ -n "$(git status --porcelain)" ]]; then
  echo "コミットしていない変更があります。先にコミットしてください。" >&2
  exit 1
fi
git fetch --quiet origin
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse '@{u}')" ]]; then
  echo "手元と GitHub の main がずれています。push（または pull）してから実行してください。" >&2
  exit 1
fi
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "$TAG はすでに公開されています。Info.plist のバージョンを上げてください。" >&2
  exit 1
fi

./scripts/build.sh --universal

echo "▸ $ZIP を作成"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "build/$APP_NAME.app" "$ZIP"

echo "▸ GitHub に $TAG を公開"
gh release create "$TAG" "$ZIP" \
  --target "$(git rev-parse HEAD)" \
  --title "$APP_NAME $VERSION" \
  --notes-file scripts/release-notes.md \
  --generate-notes

echo "▸ Homebrew の tap を更新"
./scripts/update-tap.sh
