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
    }

    struct Meta: Codable {
        var startedAt: Date
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

    func create(source: Session.Source, startedAt: Date, originalFile: URL? = nil) throws -> Session {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        var name = formatter.string(from: startedAt)
        if let originalFile {
            let base = originalFile.deletingPathExtension().lastPathComponent
                .components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            name += "_" + String(base.prefix(40))
        }

        let files = FileManager.default
        var folder = baseFolder.appendingPathComponent(name)
        var suffix = 2
        while files.fileExists(atPath: folder.path) {
            folder = baseFolder.appendingPathComponent("\(name)-\(suffix)")
            suffix += 1
        }
        try files.createDirectory(at: folder, withIntermediateDirectories: true)

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
