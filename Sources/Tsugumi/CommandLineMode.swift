import Foundation

/// メニューバーを出さずに、取り込みや録音を1回だけ実行する。動作確認用。
///
///     Tsugumi transcribe <音声ファイル> <出力フォルダ>
///     Tsugumi record <秒数> <出力フォルダ>
///     Tsugumi resume <出力フォルダ>   … 途中で終わった録音を拾って文字起こしする
///     Tsugumi selftest <出力フォルダ> … 合成した音で、変換と時間合わせを確かめる
@MainActor
enum CommandLineMode {
    static let commands: Set<String> = ["transcribe", "record", "resume", "selftest"]

    static func run(_ arguments: [String]) -> Never {
        Task { @MainActor in
            do {
                if arguments[0] == "selftest", arguments.count == 2 {
                    let folder = URL(fileURLWithPath: arguments[1])
                    let audio = try SelfTest.run(folder: folder)
                    let queue = try await SelfTest.runQueueGuard(folder: folder)
                    exit(audio && queue ? 0 : 1)
                }
                guard arguments.count == (arguments[0] == "resume" ? 2 : 3), let folder = arguments.last else {
                    throw TsugumiError.message("使い方: Tsugumi transcribe <ファイル> <出力フォルダ> / record <秒数> <出力フォルダ> / resume <出力フォルダ>")
                }
                let store = SessionStore(baseFolder: URL(fileURLWithPath: folder))
                let sessions = try await sessions(for: arguments, store: store)
                for session in sessions {
                    let finished = try await transcribe(session)
                    print(finished.transcriptURL.path)
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("エラー: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }

    private static func sessions(for arguments: [String], store: SessionStore) async throws -> [Session] {
        switch arguments[0] {
        case "transcribe":
            let source = URL(fileURLWithPath: arguments[1])
            return [try store.create(source: .imported, startedAt: Date(), originalFile: source)]
        case "record":
            return [try await record(seconds: Double(arguments[1]) ?? 5, store: store)]
        default:
            return try store.sessions(with: [.recording, .recorded]).map { found in
                var session = found
                session.meta.status = .recorded
                try session.save()
                return session
            }
        }
    }

    private static func record(seconds: Double, store: SessionStore) async throws -> Session {
        var session = try store.create(source: .recording, startedAt: Date())
        let recorder = Recorder()
        do {
            try await recorder.start(folder: session.folder)
        } catch {
            try? FileManager.default.removeItem(at: session.folder)
            throw error
        }
        try await Task.sleep(for: .seconds(seconds))
        if let error = await recorder.stop() { throw error }
        session.meta.status = .recorded
        try session.save()
        return session
    }

    private static func transcribe(_ session: Session) async throws -> Session {
        let pipeline = Pipeline()
        return try await withCheckedThrowingContinuation { continuation in
            pipeline.onFinished = { finished, error in
                _ = pipeline // 終わるまで保持する
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: finished)
                }
            }
            pipeline.enqueue(session)
        }
    }
}
