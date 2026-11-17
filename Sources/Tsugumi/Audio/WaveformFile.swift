import AVFoundation
import Foundation

/// 録音の波形の保存と読み直し。0.1 秒ごとの最大振幅を（相手, 自分）の Float32 で並べたもの
enum WaveformFile {
    static let name = "waveform.bin"
    static let interval: TimeInterval = 0.1

    static func url(in folder: URL) -> URL { folder.appendingPathComponent(name) }

    static func save(_ peaks: [AudioLevels], to folder: URL) throws {
        var data = Data(capacity: peaks.count * 8)
        for peak in peaks {
            withUnsafeBytes(of: peak.system) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: peak.mic) { data.append(contentsOf: $0) }
        }
        try data.write(to: url(in: folder), options: .atomic)
    }

    static func load(from folder: URL) -> [AudioLevels]? {
        guard let data = try? Data(contentsOf: url(in: folder)), data.count % 8 == 0, !data.isEmpty else { return nil }
        return data.withUnsafeBytes { raw in
            (0..<(raw.count / 8)).map { index in
                AudioLevels(
                    system: raw.loadUnaligned(fromByteOffset: index * 8, as: Float.self),
                    mic: raw.loadUnaligned(fromByteOffset: index * 8 + 4, as: Float.self)
                )
            }
        }
    }

    /// 音声ファイルから作る。取り込んだファイルや、波形を残していない古い録音のため。
    /// 1 本の音なので相手と自分に同じ値を入れ、上下対称に描かれる
    static func scan(_ url: URL) async throws -> [AudioLevels] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TsugumiError.message("音声トラックがありません")
        }
        let reader = try AVAssetReader(asset: asset)
        let rate = 16_000
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? TsugumiError.message("音声を読めません") }

        let perBin = Int(Double(rate) * interval)
        var peaks: [AudioLevels] = []
        var binPeak: Float = 0
        var binCount = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard var block = sample.dataBuffer else { continue }
            // 分かれて届いた塊は一続きにしてから読む（先頭の塊だけ読むと音が抜ける）
            if !block.isContiguous {
                var joined: CMBlockBuffer?
                let status = CMBlockBufferCreateContiguous(
                    allocator: kCFAllocatorDefault, sourceBuffer: block, blockAllocator: nil, customBlockSource: nil,
                    offsetToData: 0, dataLength: 0, flags: 0, blockBufferOut: &joined
                )
                guard status == noErr, let joined else { throw TsugumiError.message("音声を読めません") }
                block = joined
            }
            try block.withUnsafeMutableBytes { raw in
                for value in raw.bindMemory(to: Float.self) {
                    binPeak = max(binPeak, abs(value))
                    binCount += 1
                    if binCount == perBin {
                        peaks.append(AudioLevels(system: binPeak, mic: binPeak))
                        binPeak = 0
                        binCount = 0
                    }
                }
            }
        }
        if binCount > 0 { peaks.append(AudioLevels(system: binPeak, mic: binPeak)) }
        return peaks
    }
}
