import AppKit
import AVFoundation
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private enum State {
        case idle
        case starting
        case recording(Session, since: Date)
        case stopping
    }

    private static let detectKey = "detectMeetings"

    private let store = SessionStore()
    private let pipeline = Pipeline()
    private let notifier = Notifier()
    private let models = ModelStore()
    private let micMonitor = MicActivityMonitor()
    private lazy var library = LibraryModel(store: store)
    private var libraryWindow: NSWindow?

    private var statusItem: NSStatusItem!
    private var recorder: Recorder?
    private var state: State = .idle
    private var timer: Timer?
    private var hotKey: HotKey?
    private var lastMeetingNotice = Date.distantPast

    // MARK: - 起動と終了

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Self.detectKey: true])

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        if let button = statusItem.button {
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.imagePosition = .imageLeading
            // メニューバーのアイコンにファイルを落とせるようにする
            let dropView = DropView(frame: button.bounds)
            dropView.autoresizingMask = [.width, .height]
            dropView.onDrop = { [weak self] urls in self?.importFiles(urls) }
            button.addSubview(dropView)
        }

        pipeline.onChange = { [weak self] in self?.render() }
        pipeline.onFinished = { [weak self] session, error in self?.transcriptionFinished(session, error: error) }
        notifier.onStartRequested = { [weak self] in self?.startRecording() }
        notifier.onOpenSession = { [weak self] folder in self?.showLibrary(selecting: folder) }
        library.actions = .init(
            toggleRecording: { [weak self] in self?.toggleRecording() },
            retry: { [weak self] session in self?.retry(session) },
            importFiles: { [weak self] urls in self?.importFiles(urls) },
            willDelete: { [weak self] session in self?.pipeline.discard(folder: session.folder) }
        )
        NSApp.mainMenu = Self.makeMainMenu()
        // Dock と ⌘Tab に出るアイコンを明示する。起動後に「普通のアプリ」へ切り替える作りだと、
        // macOS が古い（アイコン無しの頃の）絵を使い続けることがあるため
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        notifier.setUp()

        // ⌃⌥⌘R で録音の開始／停止
        hotKey = HotKey(keyCode: kVK_ANSI_R, modifiers: controlKey | optionKey | cmdKey) { [weak self] in
            self?.toggleRecording()
        }
        micMonitor.onChange = { [weak self] inUse in self?.micActivityChanged(inUse) }
        micMonitor.start()

        models.onChange = { [weak self] in self?.modelStateChanged() }
        models.onReady = { [weak self] in self?.pipeline.kick() }
        library.actions.retryModelDownload = { [weak self] in self?.models.retry() }

        render()
        resumeUnfinished()
        showLibrary()
        models.ensure()
    }

    private func modelStateChanged() {
        library.setModelStatus(models.progressText, failed: { if case .failed = models.state { return true }; return false }())
        render()
    }

    /// 起動済みのアプリをもう一度開いたとき（Finder でダブルクリックなど）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLibrary()
        return false
    }

    // MARK: - 録音一覧ウィンドウ

    private func showLibrary(selecting folder: URL? = nil) {
        library.reload()
        if let folder { library.selection = folder.path }

        if libraryWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "Tsugumi"
            window.contentViewController = NSHostingController(rootView: LibraryView(model: library))
            window.setContentSize(NSSize(width: 980, height: 640))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("Library")
            libraryWindow = window
        }
        // ウィンドウを出している間だけ、Dock とメニューを持つ普通のアプリとして振る舞う
        NSApp.setActivationPolicy(.regular)
        libraryWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openLibrary() {
        showLibrary()
    }

    func windowWillClose(_ notification: Notification) {
        library.player.pause()
        // 閉じたらメニューバーだけの常駐に戻る
        NSApp.setActivationPolicy(.accessory)
    }

    /// コピー＆ペーストや ⌘W など、標準のキー操作を効かせるためのメニュー。
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        func submenu(_ title: String, _ items: [(String, Selector, String, NSEvent.ModifierFlags)?]) {
            let menu = NSMenu(title: title)
            for item in items {
                guard let (label, action, key, modifiers) = item else {
                    menu.addItem(.separator())
                    continue
                }
                let entry = menu.addItem(withTitle: label, action: action, keyEquivalent: key)
                entry.keyEquivalentModifierMask = modifiers
            }
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
        }

        submenu("Tsugumi", [
            ("Tsugumi を終了", #selector(NSApplication.terminate(_:)), "q", .command),
        ])
        submenu("編集", [
            ("取り消す", Selector(("undo:")), "z", .command),
            ("やり直す", Selector(("redo:")), "z", [.command, .shift]),
            nil,
            ("カット", #selector(NSText.cut(_:)), "x", .command),
            ("コピー", #selector(NSText.copy(_:)), "c", .command),
            ("ペースト", #selector(NSText.paste(_:)), "v", .command),
            ("すべてを選択", #selector(NSText.selectAll(_:)), "a", .command),
        ])
        submenu("ウインドウ", [
            ("閉じる", #selector(NSWindow.performClose(_:)), "w", .command),
            ("しまう", #selector(NSWindow.performMiniaturize(_:)), "m", .command),
        ])
        return main
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 文字起こしの途中なら止める。次回起動時に続きから再開する
        pipeline.cancelAll()
        guard case .recording(var session, _) = state, let recorder else { return .terminateNow }

        // 録音中に終了されたら、ファイルを閉じてから終わる
        state = .stopping
        Task {
            await recorder.stop()
            session.meta.status = .recorded
            try? session.save()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// 前回、録音中や文字起こし中に終わってしまった分を拾い直す。
    private func resumeUnfinished() {
        var crashed = false
        for var session in store.sessions(with: [.recording, .recorded]) {
            if session.meta.status == .recording { crashed = true }
            session.meta.status = .recorded
            try? session.save()
            pipeline.enqueue(session)
        }
        if crashed {
            notifier.notify(title: "前回の録音が途中で終わっていました", body: "残っていた音声を文字起こししています。")
        }
    }

    // MARK: - 録音

    @objc private func toggleRecording() {
        switch state {
        case .idle: startRecording()
        case .recording: stopRecording()
        case .starting, .stopping: break
        }
    }

    private func startRecording() {
        guard case .idle = state else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            showAlert(
                title: "「画面収録とシステムオーディオ録音」の許可が必要です",
                message: "Mac から出る音を録るために使います（画面は記録しません）。\n\nシステム設定 > プライバシーとセキュリティ > 画面収録とシステムオーディオ録音 で Tsugumi をオンにしてから、Tsugumi を起動し直してください。"
            )
            return
        }

        state = .starting
        render()
        Task {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                state = .idle
                render()
                showAlert(
                    title: "マイクの許可が必要です",
                    message: "システム設定 > プライバシーとセキュリティ > マイク で Tsugumi をオンにしてください。"
                )
                return
            }
            do {
                var session = try store.create(source: .recording, startedAt: Date())
                session.meta.microphone = Microphones.current()?.name
                try session.save()
                let recorder = Recorder()
                recorder.onInterrupted = { [weak self] _ in self?.recordingInterrupted() }
                do {
                    try await recorder.start(folder: session.folder, microphoneID: Microphones.selected()?.id)
                } catch {
                    try? FileManager.default.removeItem(at: session.folder)
                    throw error
                }
                self.recorder = recorder
                state = .recording(session, since: Date())
                library.reload()
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.render() }
                }
            } catch {
                state = .idle
                showAlert(title: "録音を開始できませんでした", message: error.localizedDescription)
            }
            render()
        }
    }

    private func stopRecording() {
        guard case .recording(let session, _) = state, let recorder else { return }
        state = .stopping
        timer?.invalidate()
        render()
        Task {
            let writeError = await recorder.stop()
            finishRecording(session)
            if let writeError {
                notifier.notify(title: "録音の一部を書き込めませんでした", body: writeError.localizedDescription)
            }
        }
    }

    /// スリープなどで録音が勝手に止まったとき。そこまでの音声は残っているので文字起こしに回す。
    private func recordingInterrupted() {
        guard case .recording(let session, _) = state else { return }
        timer?.invalidate()
        finishRecording(session)
        notifier.notify(title: "録音が中断されました", body: "そこまでの音声は保存され、文字起こしを始めています。")
    }

    private func finishRecording(_ recorded: Session) {
        var session = recorded
        recorder = nil
        session.meta.status = .recorded
        try? session.save()
        state = .idle
        pipeline.enqueue(session)
        library.reload()
        render()
    }

    // MARK: - ファイル取り込み

    @objc private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .audiovisualContent]
        panel.message = "文字起こしする音声・動画ファイルを選んでください"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    private func importFiles(_ urls: [URL]) {
        var rejected: [String] = []
        for url in urls {
            guard AudioImporter.supportedExtensions.contains(url.pathExtension.lowercased()) else {
                rejected.append(url.lastPathComponent)
                continue
            }
            // 会議の日時は、録音ファイルが作られた日時とみなす
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            do {
                let session = try store.create(source: .imported, startedAt: created, originalFile: url)
                pipeline.enqueue(session)
            } catch {
                showAlert(title: "取り込めませんでした", message: error.localizedDescription)
            }
        }
        library.reload()
        if !rejected.isEmpty {
            showAlert(title: "対応していない形式です", message: rejected.joined(separator: "\n"))
        }
    }

    private func transcriptionFinished(_ session: Session, error: Error?) {
        library.reload()
        if let error {
            notifier.notify(title: "文字起こしに失敗しました", body: error.localizedDescription, openFolder: session.folder)
        } else {
            let length = TranscriptFormatter.durationText(session.meta.durationSeconds ?? 0)
            notifier.notify(
                title: "文字起こしが終わりました",
                body: "\(session.folder.lastPathComponent)（\(length)）",
                openFolder: session.folder
            )
        }
    }

    // MARK: - 会議の検知

    private func micActivityChanged(_ inUse: Bool) {
        guard inUse, UserDefaults.standard.bool(forKey: Self.detectKey), case .idle = state else { return }
        Task {
            // 音声入力など一瞬だけの使用で通知しないよう、少し待って確かめる
            try? await Task.sleep(for: .seconds(3))
            guard micMonitor.isMicInUse, case .idle = state,
                  Date().timeIntervalSince(lastMeetingNotice) > 60 else { return }
            lastMeetingNotice = Date()
            notifier.notifyMeetingDetected()
        }
    }

    // MARK: - メニューバーの表示

    private func render() {
        if case .recording(_, let since) = state {
            library.setRecording(since: since)
        } else {
            library.setRecording(since: nil)
        }
        library.setTranscribing(id: pipeline.current?.folder.path, progress: pipeline.progress)

        guard let button = statusItem.button else { return }
        var symbol = "waveform"
        var title = ""
        var tint: NSColor?

        switch state {
        case .recording(_, let since):
            symbol = "record.circle.fill"
            tint = .systemRed
            title = " " + Self.clock(Date().timeIntervalSince(since))
        case .starting, .stopping:
            symbol = "ellipsis.circle"
        case .idle:
            if case .downloading(let received, let total) = models.state {
                symbol = "arrow.down.circle"
                title = total > 0 ? " \(Int(Double(received) / Double(total) * 100))%" : ""
            } else if pipeline.isBusy {
                symbol = "text.bubble"
                title = " \(pipeline.progress)%"
            }
        }

        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Tsugumi")
        if let tint {
            image = image?.withSymbolConfiguration(.init(paletteColors: [tint]))
            image?.isTemplate = false
        } else {
            image?.isTemplate = true
        }
        button.image = image
        button.title = title
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        func add(_ title: String, _ action: Selector?, key: String = "", checked: Bool = false) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.state = checked ? .on : .off
            if !key.isEmpty { item.keyEquivalentModifierMask = [.control, .option, .command] }
            menu.addItem(item)
        }

        switch state {
        case .recording(_, let since):
            add("録音中 \(Self.clock(Date().timeIntervalSince(since)))", nil)
            add("録音を停止", #selector(toggleRecording), key: "r")
        case .starting:
            add("録音を準備中…", nil)
        case .stopping:
            add("録音を保存中…", nil)
        case .idle:
            add("録音を開始", #selector(toggleRecording), key: "r")
        }
        if let modelText = models.progressText {
            add(modelText, nil)
            if case .failed = models.state { add("モデルの取得をやり直す", #selector(retryModelDownload)) }
        } else if pipeline.isBusy {
            let rest = pipeline.pendingCount > 1 ? "（残り\(pipeline.pendingCount)件）" : ""
            add("文字起こし中 \(pipeline.progress)%\(rest)", nil)
        }

        menu.addItem(.separator())
        add("録音一覧を開く", #selector(openLibrary))
        add("ファイルから文字起こし…", #selector(chooseFiles))
        add("保存フォルダを開く", #selector(openBaseFolder))
        let failed = store.sessions(with: [.failed]).count
        if failed > 0 {
            add("失敗した文字起こしをやり直す（\(failed)件）", #selector(retryFailed))
        }

        menu.addItem(.separator())
        menu.addItem(microphoneMenuItem())
        add("会議の開始を検知して知らせる", #selector(toggleDetection),
            checked: UserDefaults.standard.bool(forKey: Self.detectKey))
        add("保存先を変更…", #selector(changeBaseFolder))

        menu.addItem(.separator())
        add("Tsugumi を終了", #selector(quit))
    }

    /// 「マイク: ◯◯」の行。サブメニューで選び直せる（録音中は変更できない）。
    private func microphoneMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "マイク: \(Microphones.current()?.name ?? "見つかりません")", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let selected = Microphones.selected()
        var canChange = false
        if case .idle = state { canChange = true }

        func add(_ title: String, id: String?, checked: Bool) {
            let choice = NSMenuItem(title: title, action: canChange ? #selector(selectMicrophone(_:)) : nil, keyEquivalent: "")
            choice.target = self
            choice.representedObject = id
            choice.state = checked ? .on : .off
            submenu.addItem(choice)
        }

        let systemName = Microphones.systemDefault().map { "（\($0.name)）" } ?? ""
        add("macOS の設定に従う\(systemName)", id: nil, checked: selected == nil)
        submenu.addItem(.separator())
        for microphone in Microphones.available() {
            add(microphone.name, id: microphone.id, checked: selected == microphone)
        }
        item.submenu = submenu
        return item
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - メニューの操作

    @objc private func openBaseFolder() {
        try? FileManager.default.createDirectory(at: store.baseFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.baseFolder)
    }

    @objc private func retryModelDownload() {
        models.retry()
    }

    @objc private func retryFailed() {
        store.sessions(with: [.failed]).forEach(retry)
    }

    private func retry(_ failed: Session) {
        var session = failed
        session.meta.status = .recorded
        session.meta.error = nil
        try? session.save()
        pipeline.enqueue(session)
        library.reload()
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        Microphones.select(id: sender.representedObject as? String)
    }

    @objc private func toggleDetection() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: Self.detectKey), forKey: Self.detectKey)
    }

    @objc private func changeBaseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = store.baseFolder
        panel.message = "録音と文字起こしの保存先を選んでください"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { store.setBaseFolder(url) }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// メニューバーのアイコンに重ねる透明な受け皿。ファイルのドロップだけを受け、クリックは下のボタンに通す。
private final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) は使いません")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}
