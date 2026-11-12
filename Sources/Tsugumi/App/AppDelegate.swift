import AppKit
import os
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
    /// 録音が終わったら自動で文字起こしを始めるか。初期値はオフ（自分の都合のいいときに始める）
    private static let autoTranscribeKey = "autoTranscribe"
    private var autoTranscribe: Bool { UserDefaults.standard.bool(forKey: Self.autoTranscribeKey) }
    /// 終了時に処理中・順番待ちだった録音。次回起動時にそこだけ再開する
    private static let queuedKey = "queuedFolders"
    private var savedQueue: Set<String> = []

    private let store = SessionStore()
    private let pipeline = Pipeline()
    private let notifier = Notifier()
    private let models = ModelStore()
    private let updater = Updater()
    private let micMonitor = MicActivityMonitor()
    private lazy var library = LibraryModel(store: store)
    private var libraryWindow: NSWindow?
    private lazy var settings = SettingsModel(baseFolder: store.baseFolder)
    private var settingsWindow: NSWindow?

    private var statusItem: NSStatusItem!
    private var recorder: Recorder?
    private var state: State = .idle
    private var timer: Timer?
    /// 録音中、最後に音（相手か自分）が届いた時刻。無音が続いたときの通知に使う
    private var lastSoundAt = Date()
    private var warnedSilence = false
    private static let silenceWarningAfter: TimeInterval = 5 * 60
    private var hotKey: HotKey?
    private var libraryKeyMonitor: Any?
    private static let screenCaptureAskedKey = "screenCaptureAsked"
    private var lastMeetingNotice = Date.distantPast

    // MARK: - 起動と終了

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Self.detectKey: true, Self.autoTranscribeKey: false])

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
            willDelete: { [weak self] session in self?.pipeline.discard(folder: session.folder) },
            cancelTranscription: { [weak self] session in self?.pipeline.cancel(folder: session.folder) },
            chooseFiles: { [weak self] in self?.chooseFiles() },
            selectMicrophone: { [weak self] id in
                Microphones.select(id: id)
                // 設定ウィンドウを開いていれば、そちらの表示も合わせる
                self?.settings.refresh()
            },
            transcribe: { [weak self] session in self?.retry(session) }
        )
        installLibraryKeys()
        settings.changeBaseFolder = { [weak self] in self?.changeBaseFolder() }
        settings.checkForUpdates = { [weak self] in self?.updater.check() }
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
        micMonitor.onChange = { [weak self] started in self?.micActivityChanged(started) }
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

    /// 録音一覧ウィンドウのキー操作。スペースで再生／一時停止、⌘⌫ で選んでいる録音をゴミ箱へ。
    /// 文字を打っている最中（タイトル、検索）はどちらも文字入力に任せる。
    /// SwiftUI の keyboardShortcut だと入力欄のキーまで奪ってしまうので、ここで見る
    private func installLibraryKeys() {
        libraryKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard !event.isARepeat, let window = event.window else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, window === self.libraryWindow else { return false }
                let responder = window.firstResponder
                if responder is NSTextView { return false }
                switch (Int(event.keyCode), modifiers) {
                case (kVK_Space, []):
                    guard self.library.player.isAvailable, !(responder is NSButton) else { return false }
                    // キーボードでボタンを選べる設定のときは、ボタンの「押す」をスペースに残す
                    if NSApp.isFullKeyboardAccessEnabled, !(responder === window || responder is NSTableView) { return false }
                    self.library.player.togglePlayback()
                    return true
                case (kVK_Delete, [.command]):
                    self.library.requestDeleteSelection()
                    return true
                default:
                    return false
                }
            }
            return handled ? nil : event
        }
    }

    // MARK: - 設定ウィンドウ（⌘,）

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            window.title = "設定"
            window.contentViewController = NSHostingController(rootView: SettingsView(model: settings))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("Settings")
            settingsWindow = window
        }
        settings.refresh()
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        if closing === libraryWindow { library.player.pause() }
        // 自分のウィンドウが全部閉じたら、メニューバーだけの常駐に戻る
        let stillOpen = [libraryWindow, settingsWindow].contains { window in
            guard let window, window !== closing else { return false }
            return window.isVisible || window.isMiniaturized
        }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
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
            ("アップデートを確認…", #selector(checkForUpdates), "", []),
            nil,
            ("設定…", #selector(showSettings), ",", .command),
            nil,
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
        let queuedBefore = Set(UserDefaults.standard.stringArray(forKey: Self.queuedKey) ?? [])
        for var session in store.sessions(with: [.recording, .recorded]) {
            if session.meta.status == .recording { crashed = true }
            session.meta.status = .recorded
            try? session.save()
            // 自動のときは全部。手動のときは、前回頼んであったものだけ
            if autoTranscribe || queuedBefore.contains(session.folder.path) {
                pipeline.enqueue(session)
            } else {
                pipeline.makeListeningCopy(for: session)
            }
        }
        if crashed {
            notifier.notify(
                title: "前回の録音が途中で終わっていました",
                body: autoTranscribe ? "残っていた音声を文字起こししています。" : "残っていた音声は一覧にあります。"
            )
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
            // 先にこちらの説明を出し、閉じてから macOS の許可画面を出す。
            // 同時に出すと macOS の画面がこちらの裏に隠れ、こちらをクリックした拍子に最背面へ行ってしまう
            // macOS の許可画面は最初の1回しか出ない。2回目以降はシステム設定へ案内する
            let askedBefore = UserDefaults.standard.bool(forKey: Self.screenCaptureAskedKey)
            let alert = NSAlert()
            alert.messageText = "「画面収録とシステムオーディオ録音」の許可が必要です"
            alert.informativeText = askedBefore
                ? "Mac から出る音を録るために使います。画面は記録しません。\n\nシステム設定 > プライバシーとセキュリティ > 画面収録とシステムオーディオ録音 で Tsugumi をオンにして、Tsugumi を起動し直してください。"
                : "Mac から出る音を録るために使います。画面は記録しません。\n\nOK を押すと macOS の許可画面が出ます。許可したら Tsugumi を起動し直してください。"
            alert.addButton(withTitle: askedBefore ? "システム設定を開く" : "OK")
            alert.addButton(withTitle: askedBefore ? "キャンセル" : "システム設定を開く")
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            let openSettings = askedBefore ? response == .alertFirstButtonReturn : response == .alertSecondButtonReturn
            if openSettings {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            } else if !askedBefore {
                UserDefaults.standard.set(true, forKey: Self.screenCaptureAskedKey)
                CGRequestScreenCaptureAccess()
            }
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
                recorder.onWriteError = { [weak self] error in
                    // 止めてから知るのでは遅い（マイクを替えれば残りは録れる）
                    self?.notifier.notify(title: "録音の一部を書き込めませんでした", body: error.localizedDescription)
                }
                do {
                    try await recorder.start(folder: session.folder, microphoneID: Microphones.selected()?.id)
                } catch {
                    try? FileManager.default.removeItem(at: session.folder)
                    throw error
                }
                self.recorder = recorder
                state = .recording(session, since: Date())
                lastSoundAt = Date()
                warnedSilence = false
                library.reload()
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.recordingTick() }
                }
            } catch {
                state = .idle
                showAlert(title: "録音を開始できませんでした", message: error.localizedDescription)
            }
            render()
        }
    }

    /// 録音中、1秒ごと。音量を表示に渡し、長く無音なら知らせる
    private func recordingTick() {
        if let recorder {
            let levels = recorder.takeLevels()
            library.levels.set(levels)
            if levels.hasSound {
                lastSoundAt = Date()
                warnedSilence = false
            } else if !warnedSilence, Date().timeIntervalSince(lastSoundAt) > Self.silenceWarningAfter {
                warnedSilence = true
                notifier.notify(
                    title: "5分間、音が届いていません",
                    body: "相手の音もマイクの音も入っていません。マイクの選択と、音が Mac から出ているかを確認してください。"
                )
            }
        }
        render()
    }

    private func stopRecording() {
        guard case .recording(let session, _) = state, let recorder else { return }
        state = .stopping
        timer?.invalidate()
        render()
        Task {
            // 書き込みエラーは起きた時点で知らせてある（onWriteError）
            _ = await recorder.stop()
            finishRecording(session)
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
        if autoTranscribe {
            pipeline.enqueue(session)
        } else {
            // 文字起こしは後回しでも、すぐ聞き返せるようにする
            pipeline.makeListeningCopy(for: session)
        }
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
                if autoTranscribe { pipeline.enqueue(session) }
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
        // 自分で止めたものは知らせない
        guard session.meta.status != .cancelled else { return }
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

    /// - Parameter started: 新しくマイクを使い始めたアプリの pid
    private func micActivityChanged(_ started: Set<pid_t>) {
        let log = Logger(subsystem: "io.github.kumabeam.tsugumi", category: "meeting")
        guard !started.isEmpty else { return }
        guard UserDefaults.standard.bool(forKey: Self.detectKey) else { log.notice("検知はオフ"); return }
        guard case .idle = state else { log.notice("録音中なので無視"); return }
        Task {
            // 音声入力など一瞬だけの使用で通知しないよう、少し待って、同じアプリがまだ使っているか確かめる
            try? await Task.sleep(for: .seconds(3))
            guard micMonitor.isUsingInput(started) else { log.notice("3秒以内に使い終わったので無視"); return }
            guard case .idle = state else { log.notice("録音が始まっていたので無視"); return }
            guard Date().timeIntervalSince(lastMeetingNotice) > 60 else { log.notice("前の通知から60秒以内なので無視"); return }
            lastMeetingNotice = Date()
            log.notice("会議の開始を通知")
            notifier.notifyMeetingDetected()
        }
    }

    // MARK: - メニューバーの表示

    private func render() {
        if case .idle = state { settings.isRecording = false } else { settings.isRecording = true }
        if case .recording(_, let since) = state {
            library.setRecording(since: since)
        } else {
            library.setRecording(since: nil)
            library.levels.set(AudioLevels())
        }
        library.setTranscribing(id: pipeline.current?.folder.path, progress: pipeline.progress)
        var queued = Set(pipeline.waiting.map(\.folder.path))
        if let current = pipeline.current { queued.insert(current.folder.path) }
        library.setQueued(queued)
        if queued != savedQueue {
            savedQueue = queued
            UserDefaults.standard.set(Array(queued).sorted(), forKey: Self.queuedKey)
        }

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
            if pipeline.current != nil { add("文字起こしを中止", #selector(cancelTranscription)) }
        }

        menu.addItem(.separator())
        add("録音一覧を開く", #selector(openLibrary))
        add("ファイルから文字起こし…", #selector(chooseFiles))
        let pending = pendingSessions().count
        if pending > 0 {
            add("未処理の文字起こしを始める（\(pending)件）", #selector(transcribePending))
        }
        let failed = store.sessions(with: [.failed]).count
        if failed > 0 {
            add("失敗した文字起こしをやり直す（\(failed)件）", #selector(retryFailed))
        }

        menu.addItem(.separator())
        add("設定…", #selector(showSettings))
        add("Tsugumi を終了", #selector(quit))
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - メニューの操作

    @objc private func retryModelDownload() {
        models.retry()
    }

    @objc private func cancelTranscription() {
        guard let current = pipeline.current else { return }
        pipeline.cancel(folder: current.folder)
    }

    @objc private func retryFailed() {
        store.sessions(with: [.failed]).forEach(retry)
    }

    /// 録音は終わっているが、文字起こしをまだ頼んでいないもの
    private func pendingSessions() -> [Session] {
        store.sessions(with: [.recorded]).filter { !pipeline.isQueued(folder: $0.folder) }
    }

    @objc private func transcribePending() {
        pendingSessions().forEach(retry)
    }

    private func retry(_ failed: Session) {
        // すでに処理中か順番待ちなら二重に入れない
        guard !pipeline.isQueued(folder: failed.folder) else { return }
        var session = failed
        session.meta.status = .recorded
        session.meta.error = nil
        try? session.save()
        pipeline.enqueue(session)
        library.reload()
    }

    @objc private func changeBaseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = store.baseFolder
        panel.message = "録音と文字起こしの保存先を選んでください"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            store.setBaseFolder(url)
            settings.baseFolder = url
            library.reload()
        }
    }

    @objc private func checkForUpdates() {
        updater.check()
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
