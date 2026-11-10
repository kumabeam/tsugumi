#!/bin/bash
# 配布用の zip と、アプリ内アップデート用の appcast.xml を作る。
#
# 1. whisper-cli をソースから組み立てる（初回だけ時間がかかる）
# 2. アプリをビルドして署名する
# 3. zip に固める → build/Tsugumi-<バージョン>.zip
# 4. zip に EdDSA の署名を付けて、appcast.xml（版の一覧）を書き直す
#
# そのあと手でやること:
#   a. GitHub の Releases に zip を置く（タグ v<バージョン>）
#   b. appcast.xml をコミットして push する（a の後。先に push すると、まだ無い zip を取りに行ってしまう）
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
rm -f build/Tsugumi-*.zip
ditto -c -k --keepParent build/Tsugumi.app "$ZIP"
echo "作成: $ZIP ($(du -h "$ZIP" | cut -f1))"

# appcast.xml。署名の秘密鍵はキーチェーンにある（generate_keys で作ったもの）
SPARKLE_BIN="$(find .build/artifacts -type d -path '*Sparkle/bin' -maxdepth 5 | head -1)"
"$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "https://github.com/kumabeam/tsugumi/releases/download/v$VERSION/" \
    --link "https://github.com/kumabeam/tsugumi/releases" \
    --maximum-versions 1 \
    -o appcast.xml \
    build/
echo "更新: appcast.xml"
echo
echo "次にやること:"
echo "  1. git tag v$VERSION && git push --tags"
echo "  2. https://github.com/kumabeam/tsugumi/releases/new?tag=v$VERSION で $ZIP を添付して公開"
echo "  3. git add appcast.xml && git commit -m 'chore: appcast for v$VERSION' && git push"
