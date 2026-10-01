#!/usr/bin/env bash
# テストを実行する
# Xcode がなく Command Line Tools だけの環境では、Swift Testing の場所を明示して渡す
set -euo pipefail
cd "$(dirname "$0")/.."

FLAGS=()
DEVELOPER_DIR="$(xcode-select -p)"
FRAMEWORKS="$DEVELOPER_DIR/Library/Developer/Frameworks"
if [[ "$DEVELOPER_DIR" == *CommandLineTools* && -d "$FRAMEWORKS" ]]; then
  LIBS="$DEVELOPER_DIR/Library/Developer/usr/lib"
  FLAGS=(
    -Xswiftc -F -Xswiftc "$FRAMEWORKS"
    -Xlinker -F -Xlinker "$FRAMEWORKS"
    -Xlinker -rpath -Xlinker "$FRAMEWORKS"
    -Xlinker -rpath -Xlinker "$LIBS"
  )
fi

swift test ${FLAGS[@]+"${FLAGS[@]}"} "$@"
