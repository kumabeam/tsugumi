import AVFoundation
import CoreMedia

/// 1トラック分（Mac から出た音、またはマイク）を受け取り、
/// 48kHz モノラルに直して WAV に書く。
final class TrackWriter {
    let wav: WavWriter
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    /// このトラックの時刻のずれ補正（秒）。最初のバッファで決める。
    private var bias: Double?
    private let gapTolerance = Wav.recordingRate / 10
    /// 前回 takePeak() してから届いた音の最大振幅（0〜1）。録音中の音量表示用
    private let peak = Locked<Float>(0)

    /// 直近の最大振幅を返して 0 に戻す。1秒おきに読むと「この1秒の音量」になる
    func takePeak() -> Float {
        peak.withValue { value in defer { value = 0 }; return value }
    }

    init(url: URL) throws {
        wav = try WavWriter(url: url, sampleRate: Wav.recordingRate)
    }

    /// - Parameters:
    ///   - origin: 録音全体の開始時刻。2トラックを同じ時間軸に並べるための基準。
    ///   - elapsed: 録音開始からの実時間（秒）。時刻が信用できないときの代わりに使う。
    func append(_ sampleBuffer: CMSampleBuffer, origin: CMTime, elapsed: Double) throws {
        guard let input = try Self.pcmBuffer(from: sampleBuffer) else { return }

        var offset = (sampleBuffer.presentationTimeStamp - origin).seconds
        if offset.isFinite {
            if bias == nil {
                // 基準の時計が違うトラックは、届いた時刻に合わせる
                bias = abs(offset - elapsed) < 5 ? 0 : elapsed - offset
            }
            offset += bias ?? 0
            // 音が届かなかった区間は無音で埋めて、時間軸を保つ
            let expected = Int((offset * Double(Wav.recordingRate)).rounded())
            let gap = expected - wav.frames
            if gap > gapTolerance { try wav.appendSilence(frames: gap) }
        }

        let samples = try convert(input)
        let loudest = samples.reduce(Int16(0)) { max($0, $1 == .min ? .max : abs($1)) }
        peak.withValue { $0 = max($0, Float(loudest) / 32767) }
        try wav.append(samples)
    }

    /// このバッファの最大振幅（0〜1）。録音していないときの音量表示用（ファイルには書かない）。
    /// 毎秒何百回も呼ばれるので、モノラルの配列は作らずにそのまま読む
    static func peak(of sampleBuffer: CMSampleBuffer) throws -> Float {
        guard let buffer = try pcmBuffer(from: sampleBuffer) else { return 0 }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let stride = buffer.stride
        var peak: Float = 0
        if let data = buffer.floatChannelData {
            for channel in 0..<channels {
                let samples = data[channel]
                for frame in 0..<frames { peak = max(peak, abs(samples[frame * stride])) }
            }
        } else if let data = buffer.int16ChannelData {
            for channel in 0..<channels {
                let samples = data[channel]
                for frame in 0..<frames { peak = max(peak, abs(Float(samples[frame * stride])) / 32768) }
            }
        } else if let data = buffer.int32ChannelData {
            for channel in 0..<channels {
                let samples = data[channel]
                for frame in 0..<frames { peak = max(peak, abs(Float(samples[frame * stride])) / 2_147_483_648) }
            }
        }
        return min(1, peak)
    }

    func padToLength(frames: Int) throws {
        let gap = frames - wav.frames
        if gap > 0 { try wav.appendSilence(frames: gap) }
    }

    private func convert(_ input: AVAudioPCMBuffer) throws -> [Int16] {
        // 先に自前でモノラルにまとめる。チャンネル数がいくつのマイク（複数のデバイスを束ねた
        // 機器集約デバイスなど）でも扱えるようにするため
        guard let mono = Self.downmix(input) else {
            throw TsugumiError.message("音声形式を変換できません: \(input.format)")
        }
        let sourceRate = input.format.sampleRate
        let resampled = sourceRate == Double(Wav.recordingRate) ? mono : try resample(mono, from: sourceRate)
        return resampled.map { Int16(max(-1, min(1, $0)) * 32767) }
    }

    /// 全チャンネルの平均をとってモノラルにする。
    private static func downmix(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let stride = buffer.stride
        guard frames > 0, channels > 0 else { return [] }

        var mono = [Float](repeating: 0, count: frames)
        if let data = buffer.floatChannelData {
            for channel in 0..<channels {
                let samples = data[channel]
                for frame in 0..<frames { mono[frame] += samples[frame * stride] }
            }
        } else if let data = buffer.int16ChannelData {
            for channel in 0..<channels {
                let samples = data[channel]
                for frame in 0..<frames { mono[frame] += Float(samples[frame * stride]) / 32768 }
            }
        } else if let data = buffer.int32ChannelData {
            for channel in 0..<channels {
                let samples = data[channel]
                for frame in 0..<frames { mono[frame] += Float(samples[frame * stride]) / 2_147_483_648 }
            }
        } else {
            return nil
        }
        if channels > 1 {
            let scale = 1 / Float(channels)
            for frame in 0..<frames { mono[frame] *= scale }
        }
        return mono
    }

    /// モノラルの音を録音用の周波数に変換する。変換器は使い回す（つなぎ目で音が途切れないように）。
    private func resample(_ samples: [Float], from sourceRate: Double) throws -> [Float] {
        if converter == nil || sourceFormat?.sampleRate != sourceRate {
            // 途中でマイクが切り替わると周波数が変わるので、その都度作り直す
            guard let inputFormat = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 1),
                  let outputFormat = AVAudioFormat(standardFormatWithSampleRate: Double(Wav.recordingRate), channels: 1),
                  let created = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw TsugumiError.message("サンプリング周波数を変換できません: \(sourceRate)Hz")
            }
            converter = created
            sourceFormat = inputFormat
        }
        guard let converter, let sourceFormat,
              let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let inputData = input.floatChannelData else {
            throw TsugumiError.message("音声バッファを確保できません")
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            inputData[0].update(from: source.baseAddress!, count: samples.count)
        }

        let ratio = Double(Wav.recordingRate) / sourceRate
        let capacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up)) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            throw TsugumiError.message("音声バッファを確保できません")
        }

        var provided = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if provided {
                inputStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            throw conversionError ?? TsugumiError.message("音声の変換に失敗しました")
        }
        guard let outputData = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: outputData[0], count: Int(output.frameLength)))
    }

    /// 届いた音声を AVAudioPCMBuffer に写す。形式が扱えないものならエラー（録音は続き、マイクだけ無音になる）。
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0 else { return nil }
        // AVAudioFormat(cmAudioFormatDescription:) は扱えない形式で nil を返し、Swift 側はそれに気づけず落ちる。
        // 失敗が分かる方の初期化を使う（集約デバイスなど、変わった構成のマイクで起きた）
        var asbd = streamDescription.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mChannelsPerFrame > 0, asbd.mSampleRate > 0,
              let format = makeFormat(&asbd),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw TsugumiError.message("音声形式を扱えません（\(describe(asbd))）")
        }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        guard status == noErr else {
            throw TsugumiError.message("音声を読み取れません（\(status)／\(describe(asbd))）")
        }
        return buffer
    }

    /// 3チャンネル以上は配置（レイアウト）を付けないと AVAudioFormat が作れない。
    /// 全チャンネルを平均してモノラルにするだけなので、配置の意味は問わず「順番どおり」で足りる
    private static func makeFormat(_ asbd: inout AudioStreamBasicDescription) -> AVAudioFormat? {
        let channels = asbd.mChannelsPerFrame
        if channels > 2, let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels) {
            return AVAudioFormat(streamDescription: &asbd, channelLayout: layout)
        }
        return AVAudioFormat(streamDescription: &asbd)
    }

    private static func describe(_ asbd: AudioStreamBasicDescription) -> String {
        let id = asbd.mFormatID
        let fourcc = String(bytes: [24, 16, 8, 0].map { UInt8((id >> $0) & 0xff) }, encoding: .ascii) ?? "?"
        return "\(fourcc) \(asbd.mChannelsPerFrame)ch \(Int(asbd.mSampleRate))Hz \(asbd.mBitsPerChannel)bit flags=\(asbd.mFormatFlags)"
    }
}
