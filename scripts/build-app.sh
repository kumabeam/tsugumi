#!/bin/bash
# リリースビルドして build/Tsugumi.app を作る。
# --install を付けると /Applications に入れて起動する。
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/Tsugumi.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Tsugumi "$APP/Contents/MacOS/Tsugumi"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# 開発者登録なしの簡易署名。ビルドし直すと macOS からは別のアプリに見えるため、
# 画面収録とマイクの許可をやり直す必要がある。
codesign --force --sign - --identifier io.github.kumabeam.tsugumi "$APP"

# 前のビルドに出した許可は効かなくなっているので消しておく（残すと「許可済みなのに録れない」状態になる）
tccutil reset ScreenCapture io.github.kumabeam.tsugumi >/dev/null 2>&1 || true
tccutil reset Microphone io.github.kumabeam.tsugumi >/dev/null 2>&1 || true
echo "作成: $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Tsugumi 2>/dev/null || true
    rm -rf /Applications/Tsugumi.app
    cp -R "$APP" /Applications/Tsugumi.app
    open /Applications/Tsugumi.app
    echo "インストールして起動: /Applications/Tsugumi.app"
fi
