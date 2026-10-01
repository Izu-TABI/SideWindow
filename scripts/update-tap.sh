#!/usr/bin/env bash
# Homebrew の tap（Izu-TABI/homebrew-tap）の sidewindow を、公開したリリースに合わせて更新する
#
# 使い方: ./scripts/update-tap.sh
# release.sh の最後でも実行される。build/SideWindow.zip（公開したもの）のハッシュ値を tap に書き込んで push する
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
ZIP="build/SideWindow.zip"
if [[ ! -f "$ZIP" ]]; then
  echo "$ZIP がありません。先に ./scripts/release.sh を実行してください。" >&2
  exit 1
fi
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

TAP="build/homebrew-tap"
if [[ -d "$TAP/.git" ]]; then
  git -C "$TAP" pull --quiet
else
  gh repo clone Izu-TABI/homebrew-tap "$TAP" -- --quiet
fi
# 個人のアカウントで push できるよう、この clone だけ gh の認証を使う
git -C "$TAP" config credential.https://github.com.helper ""
git -C "$TAP" config --add credential.https://github.com.helper '!gh auth git-credential'

sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$TAP/Casks/sidewindow.rb"
if git -C "$TAP" diff --quiet; then
  echo "tap の sidewindow はすでに $VERSION です"
  exit 0
fi
git -C "$TAP" commit --quiet -am "sidewindow $VERSION"
git -C "$TAP" push --quiet
echo "✓ Homebrew の tap を $VERSION に更新しました"
