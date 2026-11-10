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

/// 複数のスレッドから触る値を、鍵をかけて守る入れ物。
private final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&value) }
    }
}

/// whisper-cli を子プロセスで動かして文字起こしする。音声は Mac の外に出ない。
final class Transcriber: @unchecked Sendable {
    private let running = Locked<Process?>(nil)

    func cancel() {
        running.withValue { process in
            if let process, process.isRunning { process.terminate() }
        }
    }

    /// - Parameter diarize: ステレオ WAV を渡して、左右どちらの声かを判定させる
    func run(wav: URL, diarize: Bool, tools: WhisperTools, onProgress: @escaping @Sendable (Int) -> Void) async throws -> [Segment] {
        let outputBase = wav.deletingLastPathComponent().appendingPathComponent("whisper")
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

        // whisper は進み具合とエラーを標準エラーに出す。末尾だけ覚えておく
        let errorTail = Locked("")
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            guard let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty else { return }
            errorTail.withValue { $0 = String(($0 + text).suffix(2000)) }
            for line in text.split(separator: "\n") where line.contains("progress =") {
                let digits = line.split(separator: "=").last?.filter(\.isNumber) ?? ""
                if let percent = Int(digits) { onProgress(percent) }
            }
        }

        running.withValue { $0 = process }
        defer {
            errorPipe.fileHandleForReading.readabilityHandler = nil
            running.withValue { $0 = nil }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }

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
