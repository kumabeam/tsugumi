import AVFoundation

/// 携帯の録音や画面収録などの外部ファイルを、whisper が読める 16kHz モノラル WAV に直す。
enum AudioImporter {
    static let supportedExtensions: Set<String> = [
        "m4a", "mp3", "wav", "aiff", "aif", "caf", "flac", "aac", "mov", "mp4", "m4v", "mkv", "webm", "ogg", "opus",
    ]

    static func convert(_ source: URL, to destination: URL) async throws {
        do {
            try await convertWithAVFoundation(source, to: destination)
        } catch {
            // macOS が標準で読めない形式（mkv など）は、入っていれば ffmpeg に任せる
            try? FileManager.default.removeItem(at: destination)
            guard let ffmpeg = ffmpegURL() else { throw error }
            try runFFmpeg(ffmpeg, source: source, destination: destination)
        }
    }

    private static func convertWithAVFoundation(_ source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            throw TsugumiError.message("音声が含まれていません: \(source.lastPathComponent)")
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Wav.whisperRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? TsugumiError.message("ファイルを読めません: \(source.lastPathComponent)")
        }

        let writer = try WavWriter(url: destination, sampleRate: Wav.whisperRate)
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            if status == kCMBlockBufferNoErr { try writer.append(pcm: data) }
        }
        try writer.close()

        if reader.status == .failed {
            throw reader.error ?? TsugumiError.message("ファイルの読み込みが途中で失敗しました")
        }
        if writer.frames == 0 {
            throw TsugumiError.message("音声を取り出せませんでした: \(source.lastPathComponent)")
        }
    }

    private static func ffmpegURL() -> URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private static func runFFmpeg(_ ffmpeg: URL, source: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-y", "-loglevel", "error", "-i", source.path,
            "-vn", "-ac", "1", "-ar", String(Wav.whisperRate), "-c:a", "pcm_s16le", destination.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TsugumiError.message("この形式は変換できませんでした: \(source.lastPathComponent)")
        }
    }
}
