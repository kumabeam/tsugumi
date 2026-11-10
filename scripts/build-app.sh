#!/bin/bash
# リリースビルドして build/Tsugumi.app を作る。
# --install を付けると /Applications に入れて起動する。
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/Tsugumi.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/release/Tsugumi "$APP/Contents/MacOS/Tsugumi"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/ggml-silero-v5.1.2.bin "$APP/Contents/Resources/"

# アプリ内アップデート（Sparkle）。Swift Package として取ってきたものをアプリに同梱する
SPARKLE="$(find .build/artifacts -path '*macos-arm64_x86_64/Sparkle.framework' -maxdepth 6 | head -1)"
if [[ -z "$SPARKLE" ]]; then
    echo "Sparkle.framework が見つかりません（swift package resolve を実行してください）" >&2
    exit 1
fi
cp -R "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"

# 同梱する whisper-cli（scripts/build-whisper.sh で作る）。無いと、使う人の Mac に Homebrew の whisper-cpp が要る
if [[ -x build/whisper/whisper-cli ]]; then
    cp build/whisper/whisper-cli "$APP/Contents/MacOS/whisper-cli"
else
    echo "注意: build/whisper/whisper-cli がありません。配布用には先に scripts/build-whisper.sh を実行してください" >&2
fi

IDENTITY="${TSUGUMI_SIGN_IDENTITY:-Tsugumi Self-Signed}"
if ! security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    # 証明書が無いときは簡易署名。ビルドのたびに別のアプリに見えるので、許可はやり直しになる
    IDENTITY="-"
fi

# 中身から順に署名する（Sparkle の部品 → whisper-cli → アプリ本体）
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for part in "$FW/XPCServices/Downloader.xpc" "$FW/XPCServices/Installer.xpc" "$FW/Autoupdate" "$FW/Updater.app"; do
    codesign --force --sign "$IDENTITY" --preserve-metadata=entitlements "$part"
done
codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
[[ -x "$APP/Contents/MacOS/whisper-cli" ]] && codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/whisper-cli"
codesign --force --sign "$IDENTITY" --identifier io.github.kumabeam.tsugumi "$APP"

if [[ "$IDENTITY" == "-" ]]; then
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
