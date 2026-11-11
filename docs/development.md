# 開発メモ

## 必要なもの

- macOS 15 以上、Apple Silicon
- コマンドラインツール（`xcode-select --install`）。Swift 6.0 以上が要る。`swift --version` が 5.x ならソフトウェアアップデートで更新する。上がらなければ `sudo rm -rf /Library/Developer/CommandLineTools` してから入れ直す
- cmake（`brew install cmake`）。whisper.cpp のビルドに使う

Xcode は要らない。

## ビルド

```sh
scripts/build-whisper.sh        # whisper.cpp をソースから組み立てる（初回だけ）
scripts/build-app.sh            # build/Tsugumi.app を作る
scripts/build-app.sh --install  # /Applications に入れて起動する
scripts/package.sh              # 上の全部をやって build/Tsugumi-x.y.z.zip を作る
```

`build-whisper.sh` を飛ばすと、アプリは Homebrew の `whisper-cpp` と `~/.cache/whisper/ggml-large-v3.bin` を探しに行く。開発中の近道で、配布物には使えない。

アイコンは `scripts/make-icon.swift` が描いている（仮）。描き直したら PNG を各サイズに縮小し、`iconutil` で `Resources/AppIcon.icns` を作る。

## 署名

簡易署名のままだと、ビルドし直すたびに別のアプリと見なされ、画面収録とマイクの許可がやり直しになる。
先に一度だけ証明書を作っておく。

```sh
scripts/make-signing-cert.sh    # 自己署名の証明書をキーチェーンに入れる（1台につき1回）
```

以後の `build-app.sh` はこの証明書で署名する。別の証明書は `TSUGUMI_SIGN_IDENTITY` で指定する。

許可がおかしくなったら消してやり直す。

```sh
tccutil reset ScreenCapture io.github.kumabeam.tsugumi
tccutil reset Microphone io.github.kumabeam.tsugumi
```

## リリース

1. `Resources/Info.plist` の `CFBundleShortVersionString`（表示用、例 0.2.1）と `CFBundleVersion`（整数。毎回 +1。Sparkle はこちらで新旧を比べる）を上げる
2. `scripts/package.sh` → `build/Tsugumi-X.Y.Z.zip` と `appcast.xml` ができる
3. `git tag vX.Y.Z && git push --tags`
4. GitHub の Releases に zip を添付して公開
5. `appcast.xml` をコミットして push（**4 の後**。先に push すると、まだ無い zip を取りに行く）

## アプリ内アップデート（Sparkle）

- アプリは1日1回 `https://raw.githubusercontent.com/kumabeam/tsugumi/main/appcast.xml` を見に行き、新しい版があれば知らせる。メニューの「アップデートを確認…」で手動でも
- zip の正しさは EdDSA の署名で確かめる。公開鍵は `Info.plist` の `SUPublicEDKey`、秘密鍵はビルドする Mac のキーチェーン（`generate_keys` が入れたもの）
- **秘密鍵を失くすと、以後の更新を今のユーザーに届けられなくなる。** 控えを取る: `.build/artifacts/sparkle/Sparkle/bin/generate_keys -x 保存先` で書き出し、リポジトリの外（パスワード管理ツールなど）に置く。別の Mac でビルドするときは `generate_keys -i ファイル` で取り込む
- Developer ID（有料）は無くても更新は動く。Sparkle が隔離の印を外すので「開発元を確認できない」は初回インストールのときだけ
- 動作確認: `open -a Tsugumi --args -updateFeedURL http://127.0.0.1:8765/appcast.xml -checkUpdatesOnLaunch YES` で、手元のサーバーに置いた appcast を見に行かせられる

## 文字起こしの部品

- whisper.cpp（v1.9.5）を1つの実行ファイルにして `Contents/MacOS/whisper-cli` に同梱。Metal のプログラムも埋め込み、Apple Silicon なら世代を問わず動く
- モデル `ggml-large-v3` は初回起動時に `~/Library/Application Support/Tsugumi/` へダウンロード。`~/.cache/whisper/` にあればそれを使う
- Silero VAD（`Resources/ggml-silero-v5.1.2.bin`）で無音を飛ばし、それでも出る決まり文句（「ご視聴ありがとうございました」など）は `TranscriptFormatter.isFiller` で捨てる
- 録音は 48kHz。whisper に渡すときだけ 16kHz に落とす。作業用の WAV は1時間で約700MB、文字起こし後に消える

## 構成

```
ScreenCaptureKit ─┬─ Mac から出た音 ─→ system.wav ─┐
                  └─ マイク ─────────→ mic.wav ───┴→ ステレオに結合 → whisper-cli → transcript.md
                                                                                └→ audio.m4a
```

| 場所 | 役割 |
|---|---|
| `Audio/Recorder.swift` | ScreenCaptureKit で2トラックを受け取る |
| `Audio/TrackWriter.swift` | 48kHz モノラルに変換し、2トラックの時間軸を揃える |
| `Audio/Wav.swift` | 落ちても読める WAV の書き込み、ヘッダー修復、ステレオ結合 |
| `Audio/AudioImporter.swift` | 外部ファイルを WAV に変換 |
| `Audio/Microphones.swift` | マイクの一覧と、選んだマイクの記憶 |
| `Transcribe/` | whisper-cli の実行、モデルのダウンロード、結果の整形 |
| `Session/` | 会議フォルダの管理と、文字起こしの順番待ち |
| `Library/` | 録音一覧のウィンドウ |
| `App/` | メニューバー、ショートカット、通知、会議の検知 |

## 動作確認用のコマンド

メニューバーを出さずに同じ処理を動かせる。

```sh
.build/release/Tsugumi transcribe <音声ファイル> <出力フォルダ>
.build/release/Tsugumi resume <出力フォルダ>          # 途中で終わった録音を拾い直す
.build/release/Tsugumi record <秒数> <出力フォルダ>     # 実行元のターミナルに画面収録とマイクの許可が要る
.build/release/Tsugumi selftest <出力フォルダ>        # 合成した音で変換と時間合わせ、待ち行列の安全を確かめる
.build/release/Tsugumi fetch-model <保存フォルダ>      # 初回起動と同じモデルのダウンロードを試す（約3GB）
.build/release/Tsugumi snapshot <保存フォルダ> <出力.png> [番号] [--recording] [--model] [--find <語>] [--settings]
```
