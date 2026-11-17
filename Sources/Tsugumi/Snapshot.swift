import AppKit
import SwiftUI

/// 録音一覧ウィンドウを画面に出さずに描いて、PNG に保存する。
/// 画面収録の許可なしで見た目を確かめるための、開発用の道具。
///
///     Tsugumi snapshot <保存フォルダ> <出力.png> [何番目を選ぶか]
@MainActor
enum Snapshot {
    static func run(_ arguments: [String]) -> Never {
        guard arguments.count >= 3 else {
            FileHandle.standardError.write(Data("使い方: Tsugumi snapshot <保存フォルダ> <出力.png> [番号]\n".utf8))
            exit(1)
        }
        let store = SessionStore(baseFolder: URL(fileURLWithPath: arguments[1]))
        let output = URL(fileURLWithPath: arguments[2])
        let index = arguments.count > 3 ? Int(arguments[3]) ?? 0 : 0

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        // オフスクリーンの描画では Liquid Glass の層が写らないので、macOS 25 以前の見た目で描く
        Theme.usesLiquidGlass = false
        // 指定が無ければライトで写す（写す人の Mac の設定に左右されないように）
        application.appearance = NSAppearance(named: arguments.contains("--dark") ? .darkAqua : .aqua)

        // 再生バーの波形。本体は裏で作るが、ここでは描く前に作って保存しておく
        for session in store.sessions(with: [.done, .recorded, .failed, .cancelled])
        where WaveformFile.load(from: session.folder) == nil {
            guard let audio = session.audioURL else { continue }
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                if let peaks = try? await WaveformFile.scan(audio) { try? WaveformFile.save(peaks, to: session.folder) }
                done.signal()
            }
            done.wait()
        }

        let model = LibraryModel(store: store)
        model.reload()
        if model.items.indices.contains(index) { model.selection = model.items[index].id }
        if arguments.contains("--recording") {
            model.setRecording(since: Date().addingTimeInterval(-754))
            // 会話らしい波形。決まった並びにして、写すたびに同じ絵になるようにする
            var seed: UInt32 = 7
            func next() -> Float {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                return Float(seed >> 8) / Float(1 << 24)
            }
            // 写すまでに数秒かかるので、経過時間より少し先まで用意しておく（先の分は描かれない）
            var peaks: [AudioLevels] = []
            for index in 0..<7640 {
                let phrase = (index / 25) % 7
                let talking = phrase < 4
                let system = talking ? 0.05 + next() * 0.5 : next() * 0.01
                let mic = !talking && phrase != 6 ? 0.03 + next() * 0.35 : next() * 0.008
                peaks.append(AudioLevels(system: system, mic: mic))
            }
            model.waveform.replace(peaks)
        }
        if arguments.contains("--recording") || arguments.contains("--levels") {
            model.levels.setLive(true)
            model.levels.set(AudioLevels(system: 0.3, mic: 0.02))
        }
        if arguments.contains("--muted") { model.setMuted(true) }
        // --position <秒>: 再生位置を進めた状態で写す
        if let flag = arguments.firstIndex(of: "--position"), arguments.indices.contains(flag + 1),
           let seconds = Double(arguments[flag + 1]) {
            model.player.seek(to: seconds)
        }
        if arguments.contains("--model") {
            model.setModelStatus("文字起こしモデルを準備中 42%（1.3 GB / 3.1 GB）", failed: false)
        }
        if let flag = arguments.firstIndex(of: "--find"), arguments.indices.contains(flag + 1) {
            model.isFinding = true
            model.findText = arguments[flag + 1]
        }
        // --pending: 録音済みを「文字起こし前」のまま描く。指定が無ければ文字起こし中として描く
        if let waiting = model.items.first(where: { $0.session.meta.status == .recorded }), !arguments.contains("--pending") {
            model.setQueued([waiting.id])
            model.setTranscribing(id: waiting.id, progress: 42)
        }

        var size = NSSize(width: 980, height: 640)
        let window = SilentWindow(
            contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Tsugumi"
        if arguments.contains("--settings") {
            // 設定ウィンドウを写す
            let settings = SettingsModel(baseFolder: store.baseFolder)
            settings.refresh()
            settings.isRecording = arguments.contains("--recording")
            let controller = NSHostingController(rootView: SettingsView(model: settings))
            window.contentViewController = controller
            size = controller.view.fittingSize
        } else {
            window.contentViewController = NSHostingController(rootView: LibraryView(model: model))
        }
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()

        // 描画が落ち着くのを待ってから写す
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                guard let view = window.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                // 中身だけ写すとウィンドウの地色が入らない（ダークだと白地に白文字になる）ので、先に地色を敷く
                if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = context
                    window.effectiveAppearance.performAsCurrentDrawingAppearance {
                        window.backgroundColor.setFill()
                        view.bounds.fill()
                    }
                    NSGraphicsContext.restoreGraphicsState()
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
                do {
                    try png.write(to: output)
                    print(output.path)
                    exit(0)
                } catch {
                    exit(1)
                }
            }
        }
        application.run()
        exit(0)
    }
}

/// キー入力を受け取らないウィンドウ。写すためだけに作るので、作業中の入力を奪わないようにする。
private final class SilentWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
