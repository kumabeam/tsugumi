# Tsugumi

会議を録音して文字起こしする、macOS のメニューバーアプリ。

名前は鳥のツグミから。「口をつぐむ」が語源とされる、黙って聴いている鳥。

- Mac から出る音（相手の声）とマイク（自分の声）を同時に録る。仮想オーディオデバイスも、音声出力の切り替えも要らない
- 録音は数秒おきにディスクへ書かれる。保存操作はなく、アプリが落ちてもそこまでの音声が残る
- 止めると自動で文字起こしが走る。音声も文字起こしも Mac の外に出ない
- 携帯で録った音声や画面収録のファイルも、同じ流れで文字起こしできる

## 必要なもの

- macOS 15 以上、Apple Silicon
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp)（`brew install whisper-cpp`）
- 文字起こしモデル `~/.cache/whisper/ggml-large-v3.bin`

## ビルド

Xcode は不要。コマンドラインツール（`xcode-select --install`）だけでビルドできる。

```sh
scripts/build-app.sh            # build/Tsugumi.app を作る
scripts/build-app.sh --install  # /Applications に入れて起動する
```

初回の録音開始時に「画面収録とシステムオーディオ録音」と「マイク」の許可を求められる。
画面収録の許可は Mac から出る音を受け取るために必要なもので、画面そのものは記録していない。

開発者登録なしの簡易署名なので、ビルドし直すたびに許可のやり直しが必要になる。
古い許可が残って録音を開始できないときは、次のコマンドで消してから許可し直す。

```sh
tccutil reset ScreenCapture io.github.kumabeam.tsugumi
tccutil reset Microphone io.github.kumabeam.tsugumi
```

## 使い方

| 操作 | 方法 |
|---|---|
| 録音の開始／停止 | メニューバーのアイコン → 録音を開始、ウィンドウ左下の赤いボタン、または ⌃⌥⌘R |
| ファイルを文字起こし | メニューバーのアイコンか一覧にファイルをドロップ、またはメニュー → ファイルから文字起こし… |
| 結果を見る | 終了の通知をクリック、またはメニュー → 録音一覧を開く |

録音一覧のウィンドウでは、左に録音が並び、右に文字起こしが出る。

- 文字起こしの行をクリックすると、その時刻から再生する。再生中は読んでいる行が光る
- タイトルはクリックして書き換えられる。検索はタイトルと文字起こしの中身の両方を探す
- ウィンドウを閉じても、メニューバーには残って動き続ける

ほかのアプリがマイクを使い始めると「会議が始まったようです」と通知が出る（メニューでオフにできる）。

録音に使うマイクは、メニューの「マイク: ◯◯」に出ている。そこから選び直せる。
何も選ばなければ macOS の「サウンド」設定に従う。音の出力先は選ぶ必要がない（どこに出していても録れる）。

## 出力

既定の保存先は `~/Documents/Tsugumi/`。会議ごとにフォルダができる。

```
2026-11-09_1430/
├── transcript.md   文字起こし（時刻と「相手／自分」付き）
├── audio.m4a       録音（聞き返し用。相手と自分の声を1本に混ぜてある）
└── session.json    状態の記録
```

- 「相手／自分」は、Mac から出た音とマイクのどちらが大きいかで決めている。対面の打ち合わせを Mac のマイクだけで録った場合や、取り込んだファイルには付かない
- スピーカーで聞きながら録ると相手の声がマイクにも入るが、判定は音量の大きい側になる

## しくみ

```
ScreenCaptureKit ─┬─ Mac から出た音 ─→ system.wav ─┐
                  └─ マイク ─────────→ mic.wav ───┴→ ステレオに結合 → whisper-cli → transcript.md
                                                                                └→ audio.m4a
```

| 場所 | 役割 |
|---|---|
| `Audio/Recorder.swift` | ScreenCaptureKit で2トラックを受け取る |
| `Audio/TrackWriter.swift` | 16kHz モノラルに変換し、2トラックの時間軸を揃える |
| `Audio/Wav.swift` | 落ちても読める WAV の書き込み、ヘッダー修復、ステレオ結合 |
| `Audio/AudioImporter.swift` | 外部ファイルを WAV に変換 |
| `Audio/Microphones.swift` | マイクの一覧と、選んだマイクの記憶 |
| `Transcribe/` | whisper-cli の実行と、結果の整形 |
| `Session/` | 会議フォルダの管理と、文字起こしの順番待ち |
| `Library/` | 録音一覧のウィンドウ（一覧、文字起こしの表示、再生） |
| `App/` | メニューバー、ショートカット、通知、会議の検知 |

## 動作確認用のコマンド

メニューバーを出さずに同じ処理を動かせる。

```sh
.build/release/Tsugumi transcribe <音声ファイル> <出力フォルダ>
.build/release/Tsugumi resume <出力フォルダ>    # 途中で終わった録音を拾い直す
.build/release/Tsugumi record <秒数> <出力フォルダ>
.build/release/Tsugumi selftest <出力フォルダ>  # 合成した音で、変換と時間合わせを確かめる
.build/release/Tsugumi snapshot <保存フォルダ> <出力.png> [番号]  # ウィンドウを画面に出さずに画像にする
```

`record` は、実行元のターミナルに画面収録とマイクの許可が必要。
