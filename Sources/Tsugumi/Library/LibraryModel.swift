import AppKit
import Combine

/// 録音一覧ウィンドウが見るデータ。
@MainActor
final class LibraryModel: ObservableObject {
    struct Item: Identifiable {
        let session: Session
        var id: String { session.folder.path }

        var title: String {
            if let title = session.meta.title, !title.isEmpty { return title }
            if session.meta.source == .imported, let original = session.meta.originalFile {
                return URL(fileURLWithPath: original).deletingPathExtension().lastPathComponent
            }
            return Self.titleFormatter.string(from: session.meta.startedAt) + " の録音"
        }

        var dateText: String { Self.dateFormatter.string(from: session.meta.startedAt) }

        private static let titleFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ja_JP")
            formatter.dateFormat = "M月d日 H:mm"
            return formatter
        }()

        private static let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ja_JP")
            formatter.dateFormat = "yyyy/MM/dd HH:mm"
            return formatter
        }()
    }

    /// ウィンドウからアプリ本体に頼む操作
    struct Actions {
        var toggleRecording: () -> Void = {}
        var retry: (Session) -> Void = { _ in }
        var importFiles: ([URL]) -> Void = { _ in }
        /// 録音をゴミ箱に入れる直前（文字起こし待ちから外すため）
        var willDelete: (Session) -> Void = { _ in }
        var retryModelDownload: () -> Void = {}
        /// 文字起こしを途中でやめる（順番待ちのものも外す）
        var cancelTranscription: (Session) -> Void = { _ in }
        /// ファイルを選んで文字起こしする
        var chooseFiles: () -> Void = {}
        /// 使うマイクを変える（nil = macOS の設定に従う）
        var selectMicrophone: (String?) -> Void = { _ in }
        /// 未処理の録音の文字起こしを始める
        var transcribe: (Session) -> Void = { _ in }
    }

    @Published private(set) var items: [Item] = []
    @Published var selection: String? {
        didSet { if selection != oldValue { loadSelection() } }
    }
    @Published var search = ""
    /// 文字起こしの中の検索（⌘F）
    @Published var isFinding = false
    @Published var findText = ""
    /// 選んでいる録音の文字起こし
    @Published private(set) var lines: [TranscriptLine] = []
    @Published private(set) var recordingSince: Date?
    /// 録音中の音量（1秒おきに更新）。毎秒ウィンドウ全体を描き直さないよう、別のオブジェクトにしてある
    let levels = LevelsModel()
    @Published private(set) var transcribingID: String?
    /// 文字起こしの処理中か順番待ちの録音
    @Published private(set) var queuedIDs: Set<String> = []
    @Published private(set) var progress = 0
    /// 文字起こしモデルの準備状況。揃っていれば nil
    @Published private(set) var modelStatus: String?
    @Published private(set) var modelFailed = false
    /// ゴミ箱に入れる前の確認を出している録音（一覧の右クリックと ⌘⌫ から）
    @Published var pendingDelete: Item?

    let player = PlayerModel()
    var actions = Actions()

    private let store: SessionStore
    private var loadedKey = ""
    private var loadedAudioKey = ""
    private var searchCache: [String: String] = [:]

    init(store: SessionStore) {
        self.store = store
    }

    /// 文字起こしの中で目立たせる語。⌘F の検索語が優先、無ければ一覧の検索語
    var highlightQuery: String {
        let find = isFinding ? findText.trimmingCharacters(in: .whitespaces) : ""
        return find.isEmpty ? search.trimmingCharacters(in: .whitespaces) : find
    }

    var selectedItem: Item? {
        items.first { $0.id == selection }
    }

    /// 検索語で絞り込んだ一覧。タイトルと文字起こしの中身の両方を見る。
    var filtered: [Item] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return items }
        return items.filter { $0.title.lowercased().contains(query) || transcriptText(of: $0).contains(query) }
    }

    private func transcriptText(of item: Item) -> String {
        if let cached = searchCache[item.id] { return cached }
        let text = ((try? String(contentsOf: item.session.transcriptURL, encoding: .utf8)) ?? "").lowercased()
        searchCache[item.id] = text
        return text
    }

    // MARK: - 読み込み

    /// フォルダを読み直す。録音や文字起こしの状態が変わるたびに呼ぶ。
    func reload() {
        searchCache.removeAll()
        items = store.sessions(with: [.recording, .recorded, .done, .failed, .cancelled]).reversed().map(Item.init)
        if !items.contains(where: { $0.id == selection }) {
            selection = items.first?.id
        }
        loadSelection()
    }

    private func loadSelection() {
        guard let item = selectedItem else {
            loadedKey = ""
            loadedAudioKey = ""
            lines = []
            player.load(nil)
            return
        }
        // 同じ録音を同じ状態のまま読み直さない
        let key = "\(item.id)|\(item.session.meta.status.rawValue)"
        if key != loadedKey {
            loadedKey = key
            lines = item.session.meta.status == .done ? TranscriptDocument.load(item.session.transcriptURL) : []
        }
        loadAudioIfNeeded(for: item)
    }

    /// 音声は、聞き返し用のファイルができていれば文字起こしの途中でも読む。
    /// 同じファイルを読み直さない（再生が頭に戻ってしまうため）
    private func loadAudioIfNeeded(for item: Item) {
        let audio = Self.playableAudio(of: item.session)
        let key = "\(item.id)|\(audio?.path ?? "")"
        guard key != loadedAudioKey else { return }
        loadedAudioKey = key
        player.load(audio)
    }

    /// 再生できる音声。録音中は無い
    static func playableAudio(of session: Session) -> URL? {
        session.meta.status == .recording ? nil : session.audioURL
    }

    // MARK: - アプリ本体からの状態

    func setRecording(since: Date?) {
        if recordingSince != since { recordingSince = since }
    }

    func setModelStatus(_ text: String?, failed: Bool) {
        if modelStatus != text { modelStatus = text }
        if modelFailed != failed { modelFailed = failed }
    }

    func setQueued(_ ids: Set<String>) {
        if queuedIDs != ids { queuedIDs = ids }
    }

    /// 録音は終わっているが、文字起こしをまだ頼んでいない
    func isPending(_ item: Item) -> Bool {
        item.session.meta.status == .recorded && !queuedIDs.contains(item.id)
    }

    func setTranscribing(id: String?, progress: Int) {
        if transcribingID != id { transcribingID = id }
        if self.progress != progress { self.progress = progress }
        // 聞き返し用の音声ができたら（文字起こしの途中でも、文字起こし前でも）、その時点で再生できるようにする
        if let item = selectedItem { loadAudioIfNeeded(for: item) }
    }

    // MARK: - 操作

    func rename(_ item: Item, to title: String) {
        var session = item.session
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let new: String? = trimmed.isEmpty ? nil : trimmed
        guard new != session.meta.title else { return }
        session.meta.title = new
        try? session.save()
        reload()
    }

    func copyTranscript(of item: Item) {
        guard let text = try? String(contentsOf: item.session.transcriptURL, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func revealInFinder(_ item: Item) {
        NSWorkspace.shared.activateFileViewerSelecting([item.session.folder])
    }

    /// 録音中と文字起こし中は消せない
    func canDelete(_ item: Item) -> Bool {
        item.session.meta.status != .recording && transcribingID != item.id
    }

    /// ⌘⌫。選んでいる録音の確認ダイアログを出す
    func requestDeleteSelection() {
        guard let item = selectedItem, canDelete(item) else { return }
        pendingDelete = item
    }

    /// ゴミ箱に入れる（Finder から戻せる）。
    func moveToTrash(_ item: Item) {
        if item.id == selection { player.load(nil) }
        actions.willDelete(item.session)
        try? FileManager.default.trashItem(at: item.session.folder, resultingItemURL: nil)
        reload()
    }
}

/// 録音中の音量。LevelMeters だけが見る
@MainActor
final class LevelsModel: ObservableObject {
    @Published private(set) var current = AudioLevels()

    func set(_ levels: AudioLevels) {
        if current != levels { current = levels }
    }
}
