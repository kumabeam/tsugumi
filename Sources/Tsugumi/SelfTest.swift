import AVFoundation
import CoreMedia

/// 録音の後半（受け取った音を 48kHz モノラルに直し、時間軸に並べて書く部分）を、
/// 合成した音で確かめる。実際の録音は画面収録の許可が要るので、許可なしで回せる検査として置いている。
enum SelfTest {
    static func run(folder: URL) throws -> Bool {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var passed = true

        func check(_ name: String, _ condition: Bool, _ detail: String) {
            print("\(condition ? "OK  " : "NG  ") \(name) … \(detail)")
            if !condition { passed = false }
        }

        // 1. Mac から出る音の形（48kHz・ステレオ・チャンネル別）
        do {
            let url = folder.appendingPathComponent("selftest-stereo.wav")
            let track = try TrackWriter(url: url)
            try feed(track, sampleRate: 48_000, channels: 2, interleaved: false, seconds: 3, activeChannels: [0, 1])
            try track.wav.close()
            let seconds = Double(Wav.monoFrames(url)) / Double(Wav.recordingRate)
            let peak = try Wav.peak(url)
            check("48kHz ステレオ", abs(seconds - 3) < 0.05 && abs(peak - 16_384) < 1_000, "長さ \(seconds)秒, 最大振幅 \(peak)")
        }

        // 2. 複数の機器を束ねたマイクの形（44.1kHz・3チャンネル・混在配置、声は1チャンネルだけ）
        do {
            let url = folder.appendingPathComponent("selftest-aggregate.wav")
            let track = try TrackWriter(url: url)
            try feed(track, sampleRate: 44_100, channels: 3, interleaved: true, seconds: 3, activeChannels: [0])
            try track.wav.close()
            let seconds = Double(Wav.monoFrames(url)) / Double(Wav.recordingRate)
            let peak = try Wav.peak(url)
            check("44.1kHz 3チャンネル", abs(seconds - 3) < 0.05 && abs(peak - 16_384 / 3) < 500, "長さ \(seconds)秒, 最大振幅 \(peak)")
        }

        // 3. 途中で1秒ぶん音が届かなかったとき、無音で埋めて時間軸を保つ
        do {
            let url = folder.appendingPathComponent("selftest-gap.wav")
            let track = try TrackWriter(url: url)
            try feed(track, sampleRate: 48_000, channels: 1, interleaved: false, seconds: 1, activeChannels: [0])
            try feed(track, sampleRate: 48_000, channels: 1, interleaved: false, seconds: 1, activeChannels: [0], startAt: 2)
            try track.wav.close()
            let seconds = Double(Wav.monoFrames(url)) / Double(Wav.recordingRate)
            check("音の欠落を無音で補う", abs(seconds - 3) < 0.05, "長さ \(seconds)秒（期待 3秒）")
        }

        for name in ["selftest-stereo.wav", "selftest-aggregate.wav", "selftest-gap.wav"] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        return passed
    }

    /// 文字起こし待ちの間に録音が消され、同じ名前のフォルダで次の録音が始まったとき、
    /// 待ち行列に残った古い録音が、録音中のフォルダに手を出さないことを確かめる。
    @MainActor
    static func runQueueGuard(folder: URL) async throws -> Bool {
        let base = folder.appendingPathComponent("selftest-queue")
        try? FileManager.default.removeItem(at: base)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = SessionStore(baseFolder: base)

        // 消された古い録音（待ち行列に残っている側）
        var stale = try store.create(source: .recording, startedAt: Date().addingTimeInterval(-30))
        stale.meta.status = .recorded
        try FileManager.default.removeItem(at: stale.folder)

        // 同じ名前のフォルダで録音中の、新しい録音
        let live = Session(folder: stale.folder, meta: .init(startedAt: Date(), source: .recording, status: .recording))
        try FileManager.default.createDirectory(at: live.folder, withIntermediateDirectories: true)
        try live.save()
        let tracks = [Recorder.systemFile, Recorder.micFile].map { live.folder.appendingPathComponent($0) }
        for url in tracks {
            let track = try TrackWriter(url: url)
            try feed(track, sampleRate: 48_000, channels: 1, interleaved: false, seconds: 3, activeChannels: [0])
            try track.wav.close()
        }

        let pipeline = Pipeline()
        pipeline.enqueue(stale)
        repeat { try await Task.sleep(for: .milliseconds(200)) } while pipeline.isBusy

        let kept = tracks.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        let status = Session.load(folder: live.folder)?.meta.status
        let untouched = !FileManager.default.fileExists(atPath: live.transcriptURL.path)
        let passed = kept && status == .recording && untouched
        print("\(passed ? "OK  " : "NG  ") 録音中のフォルダを古い待ち行列から守る … 音声 \(kept ? "残っている" : "消えた"), 状態 \(status?.rawValue ?? "なし")")
        return passed
    }

    /// 文字起こしを途中でやめたとき、音声がそのまま残り「中止」の状態になることを確かめる。
    /// やっている最中の1件と、順番待ちの1件の両方。
    @MainActor
    static func runCancel(folder: URL) async throws -> Bool {
        let base = folder.appendingPathComponent("selftest-cancel")
        try? FileManager.default.removeItem(at: base)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = SessionStore(baseFolder: base)

        func makeRecording(startedAt: Date, seconds: Double) throws -> Session {
            var session = try store.create(source: .recording, startedAt: startedAt)
            let track = try TrackWriter(url: session.folder.appendingPathComponent(Recorder.micFile))
            try feed(track, sampleRate: 48_000, channels: 1, interleaved: false, seconds: seconds, activeChannels: [0])
            try track.wav.close()
            session.meta.status = .recorded
            try session.save()
            return session
        }
        let running = try makeRecording(startedAt: Date().addingTimeInterval(-120), seconds: 60)
        let queued = try makeRecording(startedAt: Date(), seconds: 3)

        guard WhisperTools.isReady else {
            print("NG   文字起こしの中止 … モデルが無いので確かめられません")
            return false
        }
        let pipeline = Pipeline()
        pipeline.enqueue(running)
        pipeline.enqueue(queued)
        // 順番待ちの方を先に外す
        pipeline.cancel(folder: queued.folder)
        // whisper が実際に動き出してから止める（準備中の中止は別の経路）
        var waited = 0
        while !pipeline.isTranscribing, waited < 150 { try await Task.sleep(for: .milliseconds(100)); waited += 1 }
        let started = pipeline.isTranscribing
        pipeline.cancel(folder: running.folder)
        waited = 0
        while pipeline.isBusy, waited < 300 { try await Task.sleep(for: .milliseconds(100)); waited += 1 }

        func check(_ session: Session) -> (ok: Bool, detail: String) {
            let status = Session.load(folder: session.folder)?.meta.status
            let kept = FileManager.default.fileExists(atPath: session.folder.appendingPathComponent(Recorder.micFile).path)
            let untouched = !FileManager.default.fileExists(atPath: session.transcriptURL.path)
            return (status == .cancelled && kept && untouched, "状態 \(status?.rawValue ?? "なし"), 音声 \(kept ? "残っている" : "消えた")")
        }
        let first = check(running)
        let second = check(queued)
        let passed = started && first.ok && second.ok && !pipeline.isBusy
        print("\(passed ? "OK  " : "NG  ") 文字起こしの中止 … 実行中: \(first.detail)\(started ? "" : "（whisper が始まる前に終わった）") / 順番待ち: \(second.detail)")
        return passed
    }

    /// 440Hz・振幅 0.5 の音を、実際の録音と同じ細切れのバッファで流し込む。
    private static func feed(
        _ track: TrackWriter, sampleRate: Double, channels: Int, interleaved: Bool,
        seconds: Double, activeChannels: Set<Int>, startAt: Double = 0
    ) throws {
        let framesPerBuffer = 1024
        let total = Int(seconds * sampleRate)
        let origin = CMTime(value: 1_000, timescale: 1)
        var position = 0
        while position < total {
            let count = min(framesPerBuffer, total - position)
            let time = startAt + Double(position) / sampleRate
            let sampleBuffer = try makeSampleBuffer(
                sampleRate: sampleRate, channels: channels, interleaved: interleaved,
                frames: count, firstFrame: Int(startAt * sampleRate) + position, activeChannels: activeChannels,
                time: origin + CMTime(seconds: time, preferredTimescale: 1_000_000)
            )
            try track.append(sampleBuffer, origin: origin, elapsed: time)
            position += count
        }
    }

    private static func makeSampleBuffer(
        sampleRate: Double, channels: Int, interleaved: Bool, frames: Int, firstFrame: Int,
        activeChannels: Set<Int>, time: CMTime
    ) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
            mBytesPerPacket: UInt32(4 * (interleaved ? channels : 1)),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * (interleaved ? channels : 1)),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        guard let format = AVAudioFormat(streamDescription: &description)
                ?? AVAudioFormat(streamDescription: &description, channelLayout: AVAudioChannelLayout(
                    layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let data = buffer.floatChannelData else {
            throw TsugumiError.message("検査用の音声を作れません")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let stride = buffer.stride
        for channel in 0..<channels {
            for frame in 0..<frames {
                let phase = 2 * Double.pi * 440 * Double(firstFrame + frame) / sampleRate
                data[channel][frame * stride] = activeChannels.contains(channel) ? Float(0.5 * sin(phase)) : 0
            }
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        var status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw TsugumiError.message("検査用の音声を作れません（\(status)）")
        }
        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: buffer.audioBufferList
        )
        guard status == noErr else {
            throw TsugumiError.message("検査用の音声を作れません（\(status)）")
        }
        return sampleBuffer
    }
}
