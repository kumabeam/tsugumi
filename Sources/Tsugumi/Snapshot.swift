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

        let model = LibraryModel(store: store)
        model.reload()
        if model.items.indices.contains(index) { model.selection = model.items[index].id }
        if arguments.contains("--recording") { model.setRecording(since: Date().addingTimeInterval(-754)) }
        if arguments.contains("--model") {
            model.setModelStatus("文字起こしモデルを準備中 42%（1.3 GB / 3.1 GB）", failed: false)
        }
        if let flag = arguments.firstIndex(of: "--find"), arguments.indices.contains(flag + 1) {
            model.isFinding = true
            model.findText = arguments[flag + 1]
        }
        if let waiting = model.items.first(where: { $0.session.meta.status == .recorded }) {
            model.setTranscribing(id: waiting.id, progress: 42)
        }

        let size = NSSize(width: 980, height: 640)
        let window = SilentWindow(
            contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Tsugumi"
        window.contentViewController = NSHostingController(rootView: LibraryView(model: model))
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()

        // 描画が落ち着くのを待ってから写す
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                guard let view = window.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
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
