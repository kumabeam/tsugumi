import Foundation

enum TsugumiError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

/// 16kHz・16bit の WAV を扱う小道具。whisper がそのまま読める形式に揃えている。
enum Wav {
    static let sampleRate = 16_000
    static let headerSize = 44
    private static let chunkBytes = 1 << 20

    static func header(channels: Int, dataBytes: Int) -> Data {
        var data = Data(capacity: headerSize)
        func text(_ value: String) { data.append(contentsOf: Array(value.utf8)) }
        func u32(_ value: Int) {
            var raw = UInt32(clamping: value).littleEndian
            withUnsafeBytes(of: &raw) { data.append(contentsOf: $0) }
        }
        func u16(_ value: Int) {
            var raw = UInt16(clamping: value).littleEndian
            withUnsafeBytes(of: &raw) { data.append(contentsOf: $0) }
        }
        text("RIFF"); u32(36 + dataBytes); text("WAVE")
        text("fmt "); u32(16); u16(1); u16(channels)
        u32(sampleRate); u32(sampleRate * channels * 2); u16(channels * 2); u16(16)
        text("data"); u32(dataBytes)
        return data
    }

    static func fileSize(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// モノラル WAV のサンプル数。ヘッダーではなく実ファイルサイズから数える。
    static func monoFrames(_ url: URL) -> Int {
        max(0, fileSize(url) - headerSize) / 2
    }

    /// 録音が途中で終わったモノラル WAV のヘッダーを、実際の長さに合わせて直す。
    static func repairMonoHeader(_ url: URL) throws {
        let size = fileSize(url)
        guard size >= headerSize else {
            throw TsugumiError.message("音声ファイルが壊れています: \(url.lastPathComponent)")
        }
        let dataBytes = (size - headerSize) / 2 * 2
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header(channels: 1, dataBytes: dataBytes))
    }

    /// 最大振幅（0〜32768）。無音トラックの判定に使う。
    static func peak(_ url: URL) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(headerSize))
        var peak = 0
        while let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty {
            chunk.withUnsafeBytes { raw in
                for sample in raw.bindMemory(to: Int16.self) {
                    let magnitude = abs(Int(sample))
                    if magnitude > peak { peak = magnitude }
                }
            }
        }
        return peak
    }

    /// 2本のモノラルを足し合わせて、1本のモノラルにする（聞き返し用）。
    /// 短い方は無音として扱う。
    static func mix(_ first: URL, _ second: URL, to output: URL) throws {
        let frames = max(monoFrames(first), monoFrames(second))
        FileManager.default.createFile(atPath: output.path, contents: header(channels: 1, dataBytes: frames * 2))
        let out = try FileHandle(forWritingTo: output)
        defer { try? out.close() }
        try out.seekToEnd()

        let firstHandle = try FileHandle(forReadingFrom: first)
        let secondHandle = try FileHandle(forReadingFrom: second)
        defer { try? firstHandle.close(); try? secondHandle.close() }
        try firstHandle.seek(toOffset: UInt64(headerSize))
        try secondHandle.seek(toOffset: UInt64(headerSize))

        let framesPerChunk = chunkBytes / 2
        var written = 0
        while written < frames {
            let count = min(framesPerChunk, frames - written)
            let firstData = try firstHandle.read(upToCount: count * 2) ?? Data()
            let secondData = try secondHandle.read(upToCount: count * 2) ?? Data()
            var sums = [Int32](repeating: 0, count: count)
            for data in [firstData, secondData] {
                data.withUnsafeBytes { raw in
                    let samples = raw.bindMemory(to: Int16.self)
                    for index in 0..<min(count, samples.count) { sums[index] += Int32(samples[index]) }
                }
            }
            // 足して範囲を超えた分は上限で止める（音割れを最小にする）
            let mixed = sums.map { Int16(clamping: $0) }
            try mixed.withUnsafeBufferPointer { try out.write(contentsOf: Data(buffer: $0)) }
            written += count
        }
    }

    /// 2本のモノラルを1本のステレオにまとめる（左 = left、右 = right）。
    /// 短い方は無音で埋める。
    static func interleave(left: URL, right: URL, to output: URL) throws {
        let frames = max(monoFrames(left), monoFrames(right))
        FileManager.default.createFile(atPath: output.path, contents: header(channels: 2, dataBytes: frames * 4))
        let out = try FileHandle(forWritingTo: output)
        defer { try? out.close() }
        try out.seekToEnd()

        let leftHandle = try FileHandle(forReadingFrom: left)
        let rightHandle = try FileHandle(forReadingFrom: right)
        defer { try? leftHandle.close(); try? rightHandle.close() }
        try leftHandle.seek(toOffset: UInt64(headerSize))
        try rightHandle.seek(toOffset: UInt64(headerSize))

        let framesPerChunk = chunkBytes / 2
        var written = 0
        while written < frames {
            let count = min(framesPerChunk, frames - written)
            let leftData = try leftHandle.read(upToCount: count * 2) ?? Data()
            let rightData = try rightHandle.read(upToCount: count * 2) ?? Data()
            var mixed = [Int16](repeating: 0, count: count * 2)
            leftData.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                for index in 0..<min(count, samples.count) { mixed[index * 2] = samples[index] }
            }
            rightData.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                for index in 0..<min(count, samples.count) { mixed[index * 2 + 1] = samples[index] }
            }
            try mixed.withUnsafeBufferPointer { try out.write(contentsOf: Data(buffer: $0)) }
            written += count
        }
    }
}

/// モノラル WAV に書き足していく。数秒ごとにヘッダーを更新するので、
/// アプリが落ちてもそこまでの音声は普通の WAV として開ける。
final class WavWriter {
    let url: URL
    private let handle: FileHandle
    private(set) var frames = 0
    private var framesAtLastPatch = 0
    private let patchInterval = Wav.sampleRate * 5

    init(url: URL) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: Wav.header(channels: 1, dataBytes: 0)) else {
            throw TsugumiError.message("ファイルを作成できません: \(url.path)")
        }
        handle = try FileHandle(forUpdating: url)
        try handle.seekToEnd()
    }

    func append(_ samples: [Int16]) throws {
        guard !samples.isEmpty else { return }
        try samples.withUnsafeBufferPointer { try handle.write(contentsOf: Data(buffer: $0)) }
        frames += samples.count
        try patchHeaderIfDue()
    }

    /// 16bit リトルエンディアンの生データをそのまま足す。
    func append(pcm data: Data) throws {
        guard data.count >= 2 else { return }
        let usable = data.count / 2 * 2
        try handle.write(contentsOf: data.prefix(usable))
        frames += usable / 2
        try patchHeaderIfDue()
    }

    func appendSilence(frames count: Int) throws {
        var remaining = count
        let block = Data(count: 64 * 1024)
        while remaining > 0 {
            let bytes = min(block.count, remaining * 2)
            try handle.write(contentsOf: block.prefix(bytes))
            remaining -= bytes / 2
        }
        frames += max(0, count)
        try patchHeaderIfDue()
    }

    private func patchHeaderIfDue() throws {
        if frames - framesAtLastPatch >= patchInterval { try patchHeader() }
    }

    private func patchHeader() throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Wav.header(channels: 1, dataBytes: frames * 2))
        try handle.seekToEnd()
        framesAtLastPatch = frames
    }

    func close() throws {
        try patchHeader()
        try handle.synchronize()
        try handle.close()
    }
}
