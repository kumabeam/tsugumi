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
        /// マイクのミュートを切り替える
        var toggleMute: () -> Void = {}
    }

    @Published private(set) var items: [Item] = [] {
        didSet { updateFiltered() }
    }
    /// 検索語で絞り込んだ一覧。items と search が変わったときだけ作り直す（描き直しのたびに全文を見ない）
    @Published private(set) var filtered: [Item] = []
    @Published var selection: String? {
        didSet { if selection != oldValue { loadSelection() } }
    }
    @Published var search = "" {
        didSet {
            if search != oldValue {
                updateFiltered()
                updateMatches()
            }
        }
    }
    /// ⌘F の、文字起こしの中の検索。一覧は絞り込まない
    @Published var isFinding = false {
        didSet { if isFinding != oldValue { updateMatches() } }
    }
    @Published var findText = "" {
        didSet { if findText != oldValue { updateMatches() } }
    }
    /// 文字起こしの中の検索（⌘F）
    /// 検索で今見ている一致（matches の何番目か）
    @Published var matchPosition = 0
    /// 選んでいる録音の文字起こし
    @Published private(set) var lines: [TranscriptLine] = [] {
        didSet { updateMatches() }
    }
    /// 選んでいる録音の文字起こしで、検索語を含む行。search と lines が変わったときだけ数え直す
    @Published private(set) var matches: [Int] = []
    @Published private(set) var recordingSince: Date?
    /// 録音中の音量（1秒おきに更新）。毎秒ウィンドウ全体を描き直さないよう、別のオブジェクトにしてある
    let levels = LevelsModel()
    let waveform = WaveformModel()
    @Published private(set) var isMuted = false
    @Published private(set) var transcribingID: String?
    /// 文字起こしの処理中か順番待ちの録音
    @Published private(set) var queuedIDs: Set<String> = []
    /// 文字起こしや聞き返し用の音声作りで、フォルダの中を使っている録音
    private var busyIDs: Set<String> = []
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
    /// 選んでいる録音の波形（再生バーの下地）。無ければ音声から作って保存する
    @Published private(set) var waveformPeaks: [AudioLevels] = []
    private var waveformTask: Task<Void, Never>?
    private var searchCache: [String: String] = [:]

    init(store: SessionStore) {
        self.store = store
    }

    /// 文字起こしの中で目立たせる語。⌘F の検索語が優先、無ければ一覧の検索語
    var highlightQuery: String {
        let find = isFinding ? findText.trimmingCharacters(in: .whitespaces) : ""
        return find.isEmpty ? search.trimmingCharacters(in: .whitespaces) : find
    }

    private func updateMatches() {
        let query = highlightQuery
        let found = query.isEmpty ? [] : lines.filter { TextSearch.contains($0.text, query) }.map(\.id)
        if found != matches { matches = found }
    }

    /// 次（+1）／前（-1）の一致へ移る。端まで行ったら反対側に回る
    func stepMatch(_ direction: Int) {
        let count = matches.count
        guard count > 0 else { return }
        matchPosition = (matchPosition + direction + count) % count
    }

    var selectedItem: Item? {
        items.first { $0.id == selection }
    }

    /// タイトルと文字起こしの中身の両方を見る。一致の数え方（大文字小文字・全角半角を区別しない）は本文の検索と同じ
    private func updateFiltered() {
        let query = search.trimmingCharacters(in: .whitespaces)
        let result = query.isEmpty ? items
            : items.filter { TextSearch.contains($0.title, query) || TextSearch.contains(transcriptText(of: $0), query) }
        filtered = result
    }

    private func transcriptText(of item: Item) -> String {
        if let cached = searchCache[item.id] { return cached }
        let text = (try? String(contentsOf: item.session.transcriptURL, encoding: .utf8)) ?? ""
        searchCache[item.id] = text
        return text
    }

    // MARK: - 読み込み

    /// フォルダを読み直す。録音や文字起こしの状態が変わるたびに呼ぶ。
    /// - Parameter selecting: 選んでいる録音のフォルダ名が変わったときの新しい id。選んだ状態と再生位置を保つ
    func reload(selecting id: String? = nil) {
        searchCache.removeAll()
        items = store.sessions(with: [.recording, .recorded, .done, .failed, .cancelled]).reversed().map(Item.init)
        if let id, id != selection {
            let position = player.currentTime
            let playing = player.isPlaying
            selection = id
            if position > 0 { player.seek(to: position, play: playing) }
        }
        if !items.contains(where: { $0.id == selection }) {
            selection = items.first?.id
        }
        loadSelection()
    }

    private func loadSelection() {
        guard let item = selectedItem else {
            loadedKey = ""
            loadedAudioKey = ""
            waveformTask?.cancel()
            waveformTask = nil
            waveformPeaks = []
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
        loadWaveform(for: item, audio: audio)
    }

    private func loadWaveform(for item: Item, audio: URL?) {
        waveformTask?.cancel()
        waveformTask = nil
        waveformPeaks = []
        guard let audio else { return }
        let folder = item.session.folder
        if let saved = WaveformFile.load(from: folder) {
            waveformPeaks = saved
            return
        }
        let id = item.id
        waveformTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            guard let peaks = try? await WaveformFile.scan(audio), !Task.isCancelled else { return }
            try? WaveformFile.save(peaks, to: folder)
            await self.showWaveform(peaks, for: id)
        }
    }

    private func showWaveform(_ peaks: [AudioLevels], for id: String) {
        if selection == id { waveformPeaks = peaks }
    }

    /// 再生できる音声。録音中は無い
    static func playableAudio(of session: Session) -> URL? {
        session.meta.status == .recording ? nil : session.audioURL
    }

    // MARK: - アプリ本体からの状態

    func setRecording(since: Date?) {
        if recordingSince != since { recordingSince = since }
    }

    func setMuted(_ muted: Bool) {
        if isMuted != muted { isMuted = muted }
    }

    func setModelStatus(_ text: String?, failed: Bool) {
        if modelStatus != text { modelStatus = text }
        if modelFailed != failed { modelFailed = failed }
    }

    func setBusy(_ ids: Set<String>) { busyIDs = ids }

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
        // 中のファイルを使っていない間だけフォルダ名も合わせる。録音中・文字起こし中のものは終わったときに合わせる
        guard isIdle(item), let moved = try? store.renameFolder(of: session) else { return reload() }
        reload(selecting: selection == item.id ? moved.folder.path : nil)
    }

    /// 録音も文字起こしもしていない（フォルダの中を誰も触っていない）
    private func isIdle(_ item: Item) -> Bool {
        item.session.meta.status != .recording && !busyIDs.contains(item.id) && transcribingID != item.id
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

/// 録音中の音の波形。録音の頭からの最大振幅を 0.1 秒ごとに持つ（3 時間で 10 万件、1 MB 弱）
@MainActor
final class WaveformModel: ObservableObject {
    static let interval: TimeInterval = 0.1
    @Published private(set) var peaks: [AudioLevels] = []

    /// 録音開始からの経過時間の枡に置いて、時間軸を保つ。値は前回読んでからの最大振幅なので、
    /// 読み取りが遅れて枡が飛んだ分も同じ値で埋める（無音で埋めると穴が開いて見える）
    func append(_ levels: AudioLevels, elapsed: TimeInterval) {
        let slot = Int(elapsed / Self.interval)
        guard slot >= 0 else { return }
        if slot < peaks.count {
            // 早く来た読み取りは、今の枡とまとめる
            guard let last = peaks.last else { return }
            peaks[peaks.count - 1] = AudioLevels(system: max(last.system, levels.system), mic: max(last.mic, levels.mic))
            return
        }
        // 大きく飛んだ分（スリープや時計の補正）は、同じ値を並べると壁になるので無音にする
        let gap = slot - peaks.count
        if gap > Self.maxFill {
            peaks.append(contentsOf: repeatElement(AudioLevels(), count: gap - Self.maxFill))
        }
        peaks.append(contentsOf: repeatElement(levels, count: min(gap, Self.maxFill) + 1))
    }

    /// 遅れた読み取りを同じ値で埋める上限（枡の数）
    private static let maxFill = 10

    func reset() { peaks = [] }
    func replace(_ peaks: [AudioLevels]) { self.peaks = peaks }
}

/// 音量。LevelMeters だけが見る。録音中だけでなく、ウィンドウを開いている間は録音前から測っている
@MainActor
final class LevelsModel: ObservableObject {
    @Published private(set) var current = AudioLevels()
    /// 音量を測れているか。測れていないとき（権限がまだ無いなど）はメーターを出さない
    @Published private(set) var isLive = false

    /// 見た目が変わるときだけ描き直す（0.1 秒おきに来るので、目盛りが同じなら捨てる）
    func set(_ levels: AudioLevels) {
        if !current.looksSame(as: levels) { current = levels }
    }

    func setLive(_ live: Bool) {
        if isLive != live { isLive = live }
    }
}
