import Foundation

/// 会議1回分のフォルダと、その状態。
struct Session {
    enum Source: String, Codable {
        case recording
        case imported
    }

    enum Status: String, Codable {
        /// 録音中。起動時にこの状態が残っていたら、前回は途中で落ちている
        case recording
        /// 録音済みで文字起こし待ち
        case recorded
        case done
        case failed
        /// 文字起こしを途中でやめた。音声は残っていて、やり直せる
        case cancelled
    }

    struct Meta: Codable {
        var startedAt: Date
        /// 一覧に出す名前。付けていなければ日時から作る
        var title: String?
        var source: Source
        var status: Status
        var originalFile: String?
        /// 録音に使ったマイクの名前
        var microphone: String?
        var durationSeconds: Double?
        var error: String?
    }

    static let metaFile = "session.json"
    static let transcriptFile = "transcript.md"
    static let audioFile = "audio.m4a"

    let folder: URL
    var meta: Meta

    var transcriptURL: URL { folder.appendingPathComponent(Self.transcriptFile) }

    /// 聞き返しに使う音声。録音なら audio.m4a、取り込みなら元のファイル。
    var audioURL: URL? {
        let recorded = folder.appendingPathComponent(Self.audioFile)
        if FileManager.default.fileExists(atPath: recorded.path) { return recorded }
        if let original = meta.originalFile, FileManager.default.fileExists(atPath: original) {
            return URL(fileURLWithPath: original)
        }
        return nil
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meta).write(to: folder.appendingPathComponent(Self.metaFile), options: .atomic)
    }

    static func load(folder: URL) -> Session? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(metaFile)),
              let meta = try? decoder.decode(Meta.self, from: data) else { return nil }
        return Session(folder: folder, meta: meta)
    }
}

/// 会議フォルダの置き場所。
final class SessionStore {
    static let folderKey = "baseFolder"
    private let override: URL?

    init(baseFolder: URL? = nil) {
        override = baseFolder
    }

    var baseFolder: URL {
        if let override { return override }
        if let saved = UserDefaults.standard.string(forKey: Self.folderKey) {
            return URL(fileURLWithPath: saved)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Tsugumi")
    }

    func setBaseFolder(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: Self.folderKey)
    }

    /// フォルダ名。日時のあとに、取り込み元のファイル名か付けた名前を添える
    static func folderName(startedAt: Date, label: String?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        var name = formatter.string(from: startedAt)
        if let label {
            let safe = String(label.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-").prefix(40))
                .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            if !safe.isEmpty { name += "_" + safe }
        }
        return name
    }

    /// 同名のフォルダがあれば -2, -3 と番号を足す。自分のフォルダ（大文字小文字だけの違いも含む）は空いている扱い
    private func vacantFolder(named name: String, except current: URL? = nil) -> URL {
        let files = FileManager.default
        func isCurrent(_ url: URL) -> Bool { url.lastPathComponent.lowercased() == current?.lastPathComponent.lowercased() }
        var folder = baseFolder.appendingPathComponent(name)
        var suffix = 2
        while !isCurrent(folder), files.fileExists(atPath: folder.path) {
            folder = baseFolder.appendingPathComponent("\(name)-\(suffix)")
            suffix += 1
        }
        if let current, isCurrent(folder) { return current }
        return folder
    }

    /// 付けた名前に合わせてフォルダ名を付け替える。中のファイルを使っている最中（録音中・文字起こし中）には呼ばない
    func renameFolder(of session: Session) throws -> Session {
        // 名前がなければ、取り込んだときの元ファイル名に戻る
        let original = session.meta.originalFile.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        let name = Self.folderName(startedAt: session.meta.startedAt, label: session.meta.title ?? original)
        let folder = vacantFolder(named: name, except: session.folder)
        guard folder.path != session.folder.path else { return session }
        try FileManager.default.moveItem(at: session.folder, to: folder)
        return Session(folder: folder, meta: session.meta)
    }

    func create(source: Session.Source, startedAt: Date, originalFile: URL? = nil) throws -> Session {
        let name = Self.folderName(startedAt: startedAt, label: originalFile?.deletingPathExtension().lastPathComponent)
        let folder = vacantFolder(named: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let session = Session(folder: folder, meta: .init(
            startedAt: startedAt,
            source: source,
            status: source == .recording ? .recording : .recorded,
            originalFile: originalFile?.path
        ))
        try session.save()
        return session
    }

    func sessions(with statuses: Set<Session.Status>) -> [Session] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: baseFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return folders
            .compactMap(Session.load(folder:))
            .filter { statuses.contains($0.meta.status) }
            .sorted { $0.meta.startedAt < $1.meta.startedAt }
    }
}
