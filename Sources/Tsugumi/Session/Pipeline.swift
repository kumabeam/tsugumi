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
    /// いまの1件だけをやめる指示が出ているか
    private var skipping = false
    private let transcriber = Transcriber()

    /// これより小さい最大振幅しかないトラックは「音が入っていない」とみなす
    private nonisolated static let silencePeak = 50

    var isBusy: Bool { current != nil || !waiting.isEmpty }
    var pendingCount: Int { waiting.count + (current == nil ? 0 : 1) }

    func enqueue(_ session: Session) {
        waiting.append(session)
        onChange?()
        kick()
    }

    /// 止まっていた処理を動かす（モデルのダウンロードが終わったときなど）。
    func kick() {
        if !running, !waiting.isEmpty { Task { await drain() } }
    }

    /// 文字起こしの準備（モデル）ができておらず、待っている状態か
    var isWaitingForModel: Bool { !waiting.isEmpty && !running && !WhisperTools.isReady }

    /// 一覧から消された録音を、待ち行列からも外す。
    func discard(folder: URL) {
        waiting.removeAll { $0.folder.path == folder.path }
        onChange?()
    }

    /// 待ち行列に入れたときの録音が、いまもそのフォルダにあるか。
    /// 待っている間に消され、同じ名前のフォルダで別の録音が始まっていることがある。
    /// そのフォルダに手を出すと、録音中の音声を消してしまう。
    private nonisolated static func isSameRecording(_ session: Session, allowing statuses: Set<Session.Status>) -> Bool {
        guard let onDisk = Session.load(folder: session.folder) else { return false }
        // 保存した日時は秒までなので、1秒未満の差は同じとみなす
        return abs(onDisk.meta.startedAt.timeIntervalSince(session.meta.startedAt)) < 1
            && statuses.contains(onDisk.meta.status)
    }

    /// 1件の文字起こしをやめる。録音の音声はそのまま残り、「やり直す」でまた始められる。
    func cancel(folder: URL) {
        if current?.folder.path == folder.path {
            skipping = true
            transcriber.cancel()
            return
        }
        guard let index = waiting.firstIndex(where: { $0.folder.path == folder.path }) else { return }
        var session = waiting.remove(at: index)
        onChange?()
        guard Self.isSameRecording(session, allowing: [.recorded]) else { return }
        session.meta.status = .cancelled
        session.meta.error = nil
        try? session.save()
        onFinished?(session, nil)
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
            // モデルがまだ無ければ、ここで止まる。揃ったら kick() で再開する
            guard WhisperTools.isReady else { break }
            var session = waiting.removeFirst()
            guard Self.isSameRecording(session, allowing: [.recorded]) else {
                onChange?()
                continue
            }
            current = session
            progress = 0
            skipping = false
            onChange?()

            var failure: Error?
            do {
                try await process(&session)
                session.meta.status = .done
                session.meta.error = nil
            } catch {
                if cancelled { break }
                if skipping {
                    session.meta.status = .cancelled
                    session.meta.error = nil
                } else {
                    failure = error
                    session.meta.status = .failed
                    session.meta.error = error.localizedDescription
                }
            }
            // 文字起こしの間に付けられた名前を、古い内容で上書きしない
            if let onDisk = Session.load(folder: session.folder) { session.meta.title = onDisk.meta.title }
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

        let duration = prepared.duration
        guard duration >= 1 else {
            throw TsugumiError.message("録音が短すぎます（1秒未満）")
        }
        session.meta.durationSeconds = duration

        // 音声の準備中に「中止」が押されていたら、whisper を始めない
        if skipping { throw CancellationError() }
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

        let finished = session
        await Task.detached(priority: .utility) {
            Self.archive(prepared, session: finished)
        }.value
    }

    // MARK: - 音声の準備

    private struct Prepared: Sendable {
        /// whisper に渡す 16kHz の音声
        var wav: URL
        var diarize: Bool
        var duration: Double
        var sourceNote: String
        /// 録音したトラックのうち、音が入っていたもの（聞き返し用の音声の材料）
        var tracks: [URL] = []
    }

    private nonisolated static let whisperInput = "whisper-input.wav"

    private nonisolated static func prepareRecording(in folder: URL) throws -> Prepared {
        let files = FileManager.default
        let system = folder.appendingPathComponent(Recorder.systemFile)
        let mic = folder.appendingPathComponent(Recorder.micFile)
        let whisper = folder.appendingPathComponent(whisperInput)

        func isActive(_ url: URL) throws -> Bool {
            guard files.fileExists(atPath: url.path) else { return false }
            try Wav.repairMonoHeader(url)
            return try Wav.peak(url) >= silencePeak
        }
        func seconds(_ url: URL) -> Double {
            Double(Wav.monoFrames(url)) / Double(Wav.recordingRate)
        }
        let systemActive = try isActive(system)
        let micActive = try isActive(mic)

        switch (systemActive, micActive) {
        case (true, true):
            // 左 = Mac から出た音（相手）、右 = マイク（自分）のステレオにして、話者を区別させる
            let stereo = folder.appendingPathComponent("stereo.wav")
            try Wav.interleave(left: system, right: mic, to: stereo)
            try Wav.downsampleForWhisper(stereo, to: whisper)
            try? files.removeItem(at: stereo)
            return Prepared(
                wav: whisper, diarize: true, duration: max(seconds(system), seconds(mic)),
                sourceNote: "Mac で録音（相手 = Mac から出た音／自分 = マイク）", tracks: [system, mic]
            )
        case (false, true):
            try Wav.downsampleForWhisper(mic, to: whisper)
            return Prepared(
                wav: whisper, diarize: false, duration: seconds(mic),
                sourceNote: "Mac で録音（マイクのみ）", tracks: [mic]
            )
        case (true, false):
            try Wav.downsampleForWhisper(system, to: whisper)
            return Prepared(
                wav: whisper, diarize: false, duration: seconds(system),
                sourceNote: "Mac で録音（Mac から出た音のみ。マイクは無音）", tracks: [system]
            )
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
        return Prepared(
            wav: wav, diarize: false, duration: Double(Wav.monoFrames(wav)) / Double(Wav.whisperRate),
            sourceNote: "ファイル取り込み（\(source.lastPathComponent)）"
        )
    }

    /// 文字起こしが済んだら、録音は聞き返し用の m4a にして作業用の WAV を消す。
    private nonisolated static func archive(_ prepared: Prepared, session: Session) {
        let files = FileManager.default
        let folder = session.folder
        let source = session.meta.source
        // 作業用の WAV を消す処理なので、別の録音のフォルダになっていたら何もしない
        guard isSameRecording(session, allowing: [.recorded]) else { return }
        let workFiles = [Recorder.systemFile, Recorder.micFile, "stereo.wav", "mix.wav", "import.wav", whisperInput]
            .map { folder.appendingPathComponent($0) }

        if source == .recording {
            // 相手と自分を混ぜて、両耳から普通に聞こえる1本にする
            guard var listening = prepared.tracks.first else { return }
            if prepared.tracks.count == 2 {
                let mix = folder.appendingPathComponent("mix.wav")
                do {
                    try Wav.mix(prepared.tracks[0], prepared.tracks[1], to: mix)
                    listening = mix
                } catch {
                    return
                }
            }

            let audio = folder.appendingPathComponent(Session.audioFile)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            process.arguments = ["-f", "m4af", "-d", "aac", "-b", "80000", listening.path, audio.path]
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
        guard isSameRecording(session, allowing: [.recorded]) else { return }
        for file in workFiles { try? files.removeItem(at: file) }
    }
}
