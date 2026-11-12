import Foundation

struct Segment {
    var start: Double
    var end: Double
    /// ステレオ判定の結果。"0" = 左（Mac から出た音）、"1" = 右（マイク）、それ以外 = 判定不能
    var speaker: String?
    var text: String
}

/// whisper-cli とモデルの場所。
struct WhisperTools {
    let cli: URL
    let model: URL
    /// 声の有無を見分けるモデル（Silero VAD）。無音の区間を whisper に渡さないために使う。
    /// 無いときは全区間を渡す（無音のところに決まり文句を作ってしまいやすい）
    let vadModel: URL?

    static let vadModelFile = "ggml-silero-v5.1.2.bin"

    static let cliKey = "whisperCLI"

    /// 文字起こしに必要なものが揃っているか（モデルのダウンロード待ちなら false）
    static var isReady: Bool { (try? locate()) != nil }

    static func locate() throws -> WhisperTools {
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser.path

        // アプリに同梱した whisper-cli を使う。無い（開発中の素の実行ファイルなど）ときだけ Homebrew のものを探す
        let cliCandidates = [
            Bundle.main.url(forAuxiliaryExecutable: "whisper-cli")?.path,
            UserDefaults.standard.string(forKey: cliKey),
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
        ].compactMap { $0 }
        guard let cli = cliCandidates.first(where: { files.isExecutableFile(atPath: $0) }) else {
            throw TsugumiError.message("whisper-cli が見つかりません。アプリに同梱されているはずのものが欠けています。")
        }

        guard let model = ModelStore.locate() else {
            throw TsugumiError.message("文字起こしモデルがまだありません（初回はダウンロードに数分かかります）")
        }
        let vadCandidates = [
            Bundle.main.url(forResource: vadModelFile, withExtension: nil)?.path,
            "\(home)/.cache/whisper/\(vadModelFile)",
        ].compactMap { $0 }
        let vad = vadCandidates.first(where: { files.fileExists(atPath: $0) })
        return WhisperTools(
            cli: URL(fileURLWithPath: cli), model: model,
            vadModel: vad.map { URL(fileURLWithPath: $0) }
        )
    }
}

/// whisper-cli を子プロセスで動かして文字起こしする。音声は Mac の外に出ない。
final class Transcriber: @unchecked Sendable {
    private enum State {
        case idle
        case running(Process)
        /// プロセスが立ち上がる前に中止された。run() が始めずに終わる
        case cancelRequested
    }

    private let state = Locked<State>(.idle)

    /// whisper が動いているか
    var isRunning: Bool {
        state.withValue { if case .running = $0 { return true } else { return false } }
    }

    /// 動いていれば止める。まだ始まっていなければ、次の run() を始めさせない
    func cancel() {
        state.withValue { state in
            if case .running(let process) = state {
                process.terminate()
            } else {
                state = .cancelRequested
            }
        }
    }

    /// 前の中止要求を消す。1件ごとに Pipeline が呼ぶ
    func reset() {
        state.withValue { $0 = .idle }
    }

    /// 会議フォルダに残す whisper の記録。遅い・失敗するときに、どの Mac で何が起きたかを後から追うためのもの
    static let logFile = "whisper.log"

    /// - Parameters:
    ///   - diarize: ステレオ WAV を渡して、左右どちらの声かを判定させる
    ///   - audioSeconds: 音声の長さ。記録に「何倍速だったか」を書くために使う
    func run(wav: URL, diarize: Bool, tools: WhisperTools, audioSeconds: Double? = nil,
             onProgress: @escaping @Sendable (Int) -> Void) async throws -> [Segment] {
        let folder = wav.deletingLastPathComponent()
        let outputBase = folder.appendingPathComponent("whisper")
        let outputJSON = outputBase.appendingPathExtension("json")
        try? FileManager.default.removeItem(at: outputJSON)

        // -mc 0: 前の文脈を引き継がせない（同じ文を延々と繰り返す誤動作を抑える）
        var arguments = [
            "-m", tools.model.path, "-f", wav.path,
            "-l", "ja", "-t", "8", "-mc", "0",
            "-oj", "-of", outputBase.path, "-pp",
        ]
        if diarize { arguments.append("-di") }
        if let vad = tools.vadModel { arguments += ["--vad", "-vm", vad.path] }

        let process = Process()
        process.executableURL = tools.cli
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe

        let log = RunLog(file: folder.appendingPathComponent(Self.logFile))
        log.write(Self.header(cli: tools.cli, model: tools.model, arguments: arguments))
        let startedAt = Date()

        // whisper は進み具合とエラーを標準エラーに出す。1行ずつ記録に残しつつ、末尾だけ覚えておく。
        // 読み終わり（EOF）まで別スレッドで読み切る。終了の合図と同時に読むのをやめると、最後の
        // 行（各工程の時間やエラー）を取りこぼすため
        let errorTail = Locked("")
        let reader = errorPipe.fileHandleForReading
        let reading = Task {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    Self.readToEnd(reader) { chunk in
                        guard let text = String(data: chunk, encoding: .utf8), !text.isEmpty else { return }
                        errorTail.withValue { $0 = String(($0 + text).suffix(2000)) }
                        var kept: [Substring] = []
                        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                            if line.contains("progress =") {
                                let digits = line.split(separator: "=").last?.filter(\.isNumber) ?? ""
                                if let percent = Int(digits) { onProgress(percent) }
                            } else if !Self.isNoise(line), !line.isEmpty {
                                kept.append(line)
                            }
                        }
                        if !kept.isEmpty { log.write(kept.joined(separator: "\n")) }
                    }
                    done.resume()
                }
            }
        }

        var launched = false
        let outcome: Result<Void, Error>
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // 中止の要求と、プロセスの開始が入れ違わないよう、同じ鍵の中で始める
                let started: Result<Void, Error> = state.withValue { state in
                    if case .cancelRequested = state { return .failure(CancellationError()) }
                    process.terminationHandler = { _ in continuation.resume() }
                    do {
                        try process.run()
                        state = .running(process)
                        return .success(())
                    } catch {
                        process.terminationHandler = nil
                        return .failure(error)
                    }
                }
                switch started {
                case .success:
                    launched = true
                    // 親側の書き口を閉じる。子が終わったときに読み口へ EOF が届くようにする
                    try? errorPipe.fileHandleForWriting.close()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        // 起動できなかったときもここで閉じて EOF を出し、読み切ってから末尾を書く
        try? errorPipe.fileHandleForWriting.close()
        await Self.wait(for: reading, upTo: .seconds(2))
        state.withValue { if case .running = $0 { $0 = .idle } }
        log.write(Self.footer(startedAt: startedAt, audioSeconds: audioSeconds, process: launched ? process : nil))
        if case .failure(let error) = outcome { throw error }

        guard process.terminationStatus == 0, let data = try? Data(contentsOf: outputJSON) else {
            let detail = errorTail.withValue { $0 }.split(separator: "\n").suffix(3).joined(separator: " / ")
            throw TsugumiError.message("whisper が途中で終了しました（終了コード \(process.terminationStatus)）\(detail)")
        }
        try? FileManager.default.removeItem(at: outputJSON)

        let decoded = try JSONDecoder().decode(WhisperOutput.self, from: data)
        return decoded.transcription.compactMap { item in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !TranscriptFormatter.isFiller(text) else { return nil }
            return Segment(
                start: Double(item.offsets.from) / 1000,
                end: Double(item.offsets.to) / 1000,
                speaker: item.speaker,
                text: text
            )
        }
    }
}

private extension Transcriber {
    /// 読み終わり（EOF）まで読み、行の切れ目ごとに渡す。
    /// 途中で切れた行は次の塊につなぐ（行の先頭で見分ける判定と、多バイト文字が壊れないように）
    static func readToEnd(_ reader: FileHandle, lines: (Data) -> Void) {
        var pending = Data()
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            if let newline = pending.lastIndex(of: 0x0A) {
                lines(pending.subdata(in: pending.startIndex..<newline))
                pending = Data(pending[(newline + 1)...])
            }
        }
        lines(pending)
    }

    /// 読み切りを待つ。相手がいつまでも閉じないときのために上限を置く
    static func wait(for task: Task<Void, Never>, upTo limit: Duration) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask { try? await Task.sleep(for: limit) }
            await group.next()
            group.cancelAll()
        }
    }

    /// 記録に残さない行。進み具合と、声の区間ひとつひとつの列挙（2時間の会議で数千行になる）
    static func isNoise(_ line: Substring) -> Bool {
        line.contains("progress =")
            || line.hasPrefix("whisper_vad_segments_from_probs: VAD segment")
            || line.hasPrefix("whisper_vad: Including segment")
            || line.hasPrefix("whisper_vad: vad_segment_info")
            || line.hasPrefix("ggml_metal_library_compile_all: compiled")
    }

    /// 記録の先頭。どの Mac で、何を使って動かしたか
    static func header(cli: URL, model: URL, arguments: [String]) -> String {
        let info = ProcessInfo.processInfo
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "開発版"
        let modelSize = (try? FileManager.default.attributesOfItem(atPath: model.path)[.size] as? Int64) ?? 0
        let cores = "高性能 \(sysctlInt("hw.perflevel0.physicalcpu") ?? 0) + 高効率 \(sysctlInt("hw.perflevel1.physicalcpu") ?? 0) コア"
        return """
        === \(Self.timestamp(Date())) Tsugumi \(version)
        Mac: \(sysctlString("machdep.cpu.brand_string") ?? "不明")（\(sysctlString("hw.model") ?? "不明")、\(cores)） / メモリ \(info.physicalMemory >> 30) GB / macOS \(info.operatingSystemVersionString)
        状態: 低電力モード \(info.isLowPowerModeEnabled ? "オン" : "オフ") / 発熱 \(thermalText(info.thermalState))
        whisper-cli: \(cli.path)
        モデル: \(model.path)（\(modelSize / 1_000_000) MB）
        引数: \(arguments.joined(separator: " "))
        """
    }

    /// 記録の末尾。かかった時間と速さ
    /// - Parameter process: 起動できなかった（または起動前に中止した）ときは nil
    static func footer(startedAt: Date, audioSeconds: Double?, process: Process?) -> String {
        let elapsed = Date().timeIntervalSince(startedAt)
        let result: String
        if let process {
            result = process.terminationReason == .uncaughtSignal
                ? "中止（シグナル \(process.terminationStatus)）"
                : "終了コード \(process.terminationStatus)"
        } else {
            result = "起動せず（起動前に中止、または起動に失敗）"
        }
        var line = "=== \(timestamp(Date())) \(result) / 所要 \(Int(elapsed)) 秒"
        if let audioSeconds, elapsed > 0 {
            line += " / 音声 \(Int(audioSeconds)) 秒（\(String(format: "%.1f", audioSeconds / elapsed)) 倍速）"
        }
        line += " / 発熱 \(thermalText(ProcessInfo.processInfo.thermalState))\n"
        return line
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size + 1)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    static func thermalText(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "通常"
        case .fair: return "やや高い"
        case .serious: return "高い（速度が落ちる）"
        case .critical: return "限界"
        @unknown default: return "不明"
        }
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

/// whisper.log への追記。文字起こしのたびに続きへ足していく（やり直しの履歴も残る）
private final class RunLog: @unchecked Sendable {
    private let handle: FileHandle?
    private let lock = NSLock()

    init(file: URL) {
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: file)
        _ = try? handle?.seekToEnd()
    }

    func write(_ text: String) {
        guard let data = (text.hasSuffix("\n") ? text : text + "\n").data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        try? handle?.write(contentsOf: data)
    }

    deinit { try? handle?.close() }
}

private struct WhisperOutput: Decodable {
    struct Item: Decodable {
        struct Offsets: Decodable {
            let from: Int
            let to: Int
        }
        let offsets: Offsets
        let text: String
        let speaker: String?
    }
    let transcription: [Item]
}
