#!/bin/bash
# 配布用の zip を作る。build/Tsugumi-<バージョン>.zip ができる。
#
# 1. whisper-cli をソースから組み立てる（初回だけ時間がかかる）
# 2. アプリをビルドして署名する
# 3. zip に固める（Finder で展開すると Tsugumi.app が出てくる）
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-whisper.sh
scripts/build-app.sh

if [[ ! -x build/Tsugumi.app/Contents/MacOS/whisper-cli ]]; then
    echo "whisper-cli が同梱されていません。配布物を作れません" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Tsugumi.app/Contents/Info.plist)"
ZIP="build/Tsugumi-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/Tsugumi.app "$ZIP"
echo "作成: $ZIP ($(du -h "$ZIP" | cut -f1))"
