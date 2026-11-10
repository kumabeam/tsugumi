#!/bin/bash
# リリースビルドして build/Tsugumi.app を作る。
# --install を付けると /Applications に入れて起動する。
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/Tsugumi.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Tsugumi "$APP/Contents/MacOS/Tsugumi"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/ggml-silero-v5.1.2.bin "$APP/Contents/Resources/"

IDENTITY="${TSUGUMI_SIGN_IDENTITY:-Tsugumi Self-Signed}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    # 決まった証明書で署名する。ビルドし直しても macOS から同じアプリとして扱われ、
    # 画面収録とマイクの許可が引き継がれる（証明書は scripts/make-signing-cert.sh で作る）
    codesign --force --sign "$IDENTITY" --identifier io.github.kumabeam.tsugumi "$APP"
else
    # 証明書が無いときは簡易署名。ビルドのたびに別のアプリに見えるので、許可はやり直しになる
    codesign --force --sign - --identifier io.github.kumabeam.tsugumi "$APP"
    # 前のビルドに出した許可は効かなくなっているので消しておく（残すと「許可済みなのに録れない」状態になる）
    tccutil reset ScreenCapture io.github.kumabeam.tsugumi >/dev/null 2>&1 || true
    tccutil reset Microphone io.github.kumabeam.tsugumi >/dev/null 2>&1 || true
    echo "簡易署名でビルドしました（許可はやり直しになります）"
fi
echo "作成: $APP"

if [[ "${1:-}" == "--install" ]]; then
    osascript -e 'quit app "Tsugumi"' 2>/dev/null || true
    sleep 1
    pkill -x Tsugumi 2>/dev/null || true
    rm -rf /Applications/Tsugumi.app
    cp -R "$APP" /Applications/Tsugumi.app
    open /Applications/Tsugumi.app
    echo "インストールして起動: /Applications/Tsugumi.app"
fi
