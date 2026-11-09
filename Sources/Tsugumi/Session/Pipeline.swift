import Foundation

/// 録音や取り込みファイルを、順番に文字起こししていく。
@MainActor
final class Pipeline {
    /// 待ち件数や進み具合が変わったとき（メニューの表示更新用）
    var onChange: (() -> Void)?
    /// 1件終わったとき。失敗なら error が入る
    var onFinished: ((Session, Error?) -> Void)?

    private(set) var waiting: [Session] = []
    private(set) var current: Session?
    private(set) var progress = 0
    private var running = false
    private var cancelled = false
    private let transcriber = Transcriber()

    /// これより小さい最大振幅しかないトラックは「音が入っていない」とみなす
    private nonisolated static let silencePeak = 50

    var isBusy: Bool { current != nil || !waiting.isEmpty }
    var pendingCount: Int { waiting.count + (current == nil ? 0 : 1) }

    func enqueue(_ session: Session) {
        waiting.append(session)
        onChange?()
        if !running { Task { await drain() } }
    }

    /// アプリ終了時に呼ぶ。途中の分は「文字起こし待ち」のまま残り、次回起動時に再開される。
    func cancelAll() {
        cancelled = true
        waiting.removeAll()
        transcriber.cancel()
    }

    private func drain() async {
        running = true
        while !waiting.isEmpty {
            var session = waiting.removeFirst()
            current = session
            progress = 0
            onChange?()

            var failure: Error?
            do {
                try await process(&session)
                session.meta.status = .done
                session.meta.error = nil
            } catch {
                if cancelled { break }
                failure = error
                session.meta.status = .failed
                session.meta.error = error.localizedDescription
            }
            try? session.save()
            current = nil
            onChange?()
            onFinished?(session, failure)
        }
        running = false
    }

    private func process(_ session: inout Session) async throws {
        let tools = try WhisperTools.locate()
        let folder = session.folder
        let source = session.meta.source
        let original = session.meta.originalFile
        let microphone = source == .recording ? session.meta.microphone : nil

        // 音声ファイルの準備は重いのでメインスレッドの外で行う
        let prepared = try await Task.detached(priority: .userInitiated) { () -> Prepared in
            switch source {
            case .recording: return try Self.prepareRecording(in: folder)
            case .imported: return try await Self.prepareImport(original: original, in: folder)
            }
        }.value

        let duration = Double(prepared.frames) / Double(Wav.sampleRate)
        guard duration >= 1 else {
            throw TsugumiError.message("録音が短すぎます（1秒未満）")
        }
        session.meta.durationSeconds = duration

        let segments = try await transcriber.run(wav: prepared.wav, diarize: prepared.diarize, tools: tools) { percent in
            Task { @MainActor [weak self] in
                self?.progress = percent
                self?.onChange?()
            }
        }

        let lines = TranscriptFormatter.lines(from: segments, labelled: prepared.diarize)
        let text = TranscriptFormatter.markdown(
            lines: lines,
            startedAt: session.meta.startedAt,
            duration: duration,
            sourceNote: prepared.sourceNote + (microphone.map { "／使用マイク: \($0)" } ?? ""),
            modelName: tools.model.deletingPathExtension().lastPathComponent
        )
        try text.write(to: session.transcriptURL, atomically: true, encoding: .utf8)

        await Task.detached(priority: .utility) {
            Self.archive(prepared, source: source, in: folder)
        }.value
    }

    // MARK: - 音声の準備

    private struct Prepared: Sendable {
        var wav: URL
        var diarize: Bool
        var frames: Int
        var sourceNote: String
    }

    private nonisolated static func prepareRecording(in folder: URL) throws -> Prepared {
        let files = FileManager.default
        let system = folder.appendingPathComponent(Recorder.systemFile)
        let mic = folder.appendingPathComponent(Recorder.micFile)

        func isActive(_ url: URL) throws -> Bool {
            guard files.fileExists(atPath: url.path) else { return false }
            try Wav.repairMonoHeader(url)
            return try Wav.peak(url) >= silencePeak
        }
        let systemActive = try isActive(system)
        let micActive = try isActive(mic)

        switch (systemActive, micActive) {
        case (true, true):
            // 左 = Mac から出た音（相手）、右 = マイク（自分）のステレオにして、話者を区別させる
            let stereo = folder.appendingPathComponent("stereo.wav")
            try Wav.interleave(left: system, right: mic, to: stereo)
            return Prepared(
                wav: stereo, diarize: true,
                frames: max(Wav.monoFrames(system), Wav.monoFrames(mic)),
                sourceNote: "Mac で録音（相手 = Mac から出た音／自分 = マイク）"
            )
        case (false, true):
            return Prepared(wav: mic, diarize: false, frames: Wav.monoFrames(mic), sourceNote: "Mac で録音（マイクのみ）")
        case (true, false):
            return Prepared(wav: system, diarize: false, frames: Wav.monoFrames(system), sourceNote: "Mac で録音（Mac から出た音のみ。マイクは無音）")
        case (false, false):
            throw TsugumiError.message("音が録れていませんでした")
        }
    }

    private nonisolated static func prepareImport(original: String?, in folder: URL) async throws -> Prepared {
        guard let original else { throw TsugumiError.message("取り込み元のファイルがわかりません") }
        let source = URL(fileURLWithPath: original)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw TsugumiError.message("取り込み元のファイルが見つかりません: \(source.lastPathComponent)")
        }
        let wav = folder.appendingPathComponent("import.wav")
        try? FileManager.default.removeItem(at: wav)
        try await AudioImporter.convert(source, to: wav)
        return Prepared(wav: wav, diarize: false, frames: Wav.monoFrames(wav), sourceNote: "ファイル取り込み（\(source.lastPathComponent)）")
    }

    /// 文字起こしが済んだら、録音は小さい m4a にして作業用の WAV を消す。
    private nonisolated static func archive(_ prepared: Prepared, source: Session.Source, in folder: URL) {
        let files = FileManager.default
        let workFiles = [Recorder.systemFile, Recorder.micFile, "stereo.wav", "mix.wav", "import.wav"]
            .map { folder.appendingPathComponent($0) }

        if source == .recording {
            // 保存するのは聞き返し用。左右に分けた音は話者の判定にしか使わないので、
            // 相手と自分を混ぜて、両耳から普通に聞こえる1本にする
            var listening = prepared.wav
            if prepared.diarize {
                let mix = folder.appendingPathComponent("mix.wav")
                do {
                    try Wav.mix(
                        folder.appendingPathComponent(Recorder.systemFile),
                        folder.appendingPathComponent(Recorder.micFile),
                        to: mix
                    )
                    listening = mix
                } catch {
                    return
                }
            }

            let audio = folder.appendingPathComponent(Session.audioFile)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            process.arguments = ["-f", "m4af", "-d", "aac", listening.path, audio.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return
            }
            // 変換できなかったときは WAV を残す（音声を失わない）
            guard process.terminationStatus == 0, Wav.fileSize(audio) > 0 else { return }
        }
        for file in workFiles { try? files.removeItem(at: file) }
    }
}
