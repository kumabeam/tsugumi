#!/bin/bash
# whisper.cpp をソースから組み立てて、アプリに同梱する whisper-cli を作る。
# 出来上がりは build/whisper/whisper-cli（1つのファイルで動く。他のライブラリに頼らない）。
#
# 必要なもの: cmake（brew install cmake）
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="v1.9.5"
SRC="build/whisper.cpp"
OUT="build/whisper"

if [[ -x "$OUT/whisper-cli" && "$(cat "$OUT/VERSION" 2>/dev/null)" == "$VERSION" ]]; then
    echo "すでにあります: $OUT/whisper-cli ($VERSION)"
    exit 0
fi

if [[ ! -d "$SRC" ]]; then
    git clone --quiet --depth 1 --branch "$VERSION" https://github.com/ggml-org/whisper.cpp.git "$SRC"
fi

# - 共有ライブラリにせず、1つの実行ファイルにまとめる
# - GPU 用のプログラム（Metal）も実行ファイルの中に埋め込む
# - このマシン専用の最適化はしない（M1 から最新まで、どの Apple Silicon でも動くように）
cmake -S "$SRC" -B "$SRC/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_NATIVE=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_SERVER=OFF \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_OSX_ARCHITECTURES=arm64 >/dev/null
cmake --build "$SRC/build" --config Release --target whisper-cli -j "$(sysctl -n hw.ncpu)" >/dev/null

mkdir -p "$OUT"
cp "$SRC/build/bin/whisper-cli" "$OUT/whisper-cli"
echo "$VERSION" > "$OUT/VERSION"
echo "作成: $OUT/whisper-cli ($VERSION)"
otool -L "$OUT/whisper-cli" | tail -n +2
