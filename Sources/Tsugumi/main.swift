import AppKit

// 引数なしで起動すればメニューバーアプリ。
// `transcribe` / `record` を付けると、画面なしで同じ処理を動かせる（動作確認用）。
MainActor.assumeIsolated {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "snapshot" {
        Snapshot.run(arguments)
    }
    if let command = arguments.first, CommandLineMode.commands.contains(command) {
        CommandLineMode.run(arguments)
    }

    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
