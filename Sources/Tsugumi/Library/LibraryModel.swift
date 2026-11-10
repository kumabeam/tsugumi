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
    @Published private(set) var transcribingID: String?
    @Published private(set) var progress = 0
    /// 文字起こしモデルの準備状況。揃っていれば nil
    @Published private(set) var modelStatus: String?
    @Published private(set) var modelFailed = false

    let player = PlayerModel()
    var actions = Actions()

    private let store: SessionStore
    private var loadedKey = ""
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
        items = store.sessions(with: [.recording, .recorded, .done, .failed]).reversed().map(Item.init)
        if !items.contains(where: { $0.id == selection }) {
            selection = items.first?.id
        }
        loadSelection()
    }

    private func loadSelection() {
        guard let item = selectedItem else {
            loadedKey = ""
            lines = []
            player.load(nil)
            return
        }
        // 同じ録音を同じ状態のまま読み直さない（再生が頭に戻ってしまうため）
        let key = "\(item.id)|\(item.session.meta.status.rawValue)"
        guard key != loadedKey else { return }
        loadedKey = key
        lines = item.session.meta.status == .done ? TranscriptDocument.load(item.session.transcriptURL) : []
        player.load(item.session.meta.status == .done ? item.session.audioURL : nil)
    }

    // MARK: - アプリ本体からの状態

    func setRecording(since: Date?) {
        if recordingSince != since { recordingSince = since }
    }

    func setModelStatus(_ text: String?, failed: Bool) {
        if modelStatus != text { modelStatus = text }
        if modelFailed != failed { modelFailed = failed }
    }

    func setTranscribing(id: String?, progress: Int) {
        if transcribingID != id { transcribingID = id }
        if self.progress != progress { self.progress = progress }
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

    /// ゴミ箱に入れる（Finder から戻せる）。
    func moveToTrash(_ item: Item) {
        if item.id == selection { player.load(nil) }
        actions.willDelete(item.session)
        try? FileManager.default.trashItem(at: item.session.folder, resultingItemURL: nil)
        reload()
    }
}
