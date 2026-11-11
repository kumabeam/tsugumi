import AVFoundation
import QuartzCore
import ScreenCaptureKit

/// 録音中の音量。最大振幅（0〜1）
struct AudioLevels: Equatable {
    var system: Float = 0
    var mic: Float = 0

    /// 聞こえる音が入っているか（最大振幅 -46dB くらいより上）
    var hasSound: Bool { max(system, mic) > 0.005 }

    /// 表示用。-60dB を 0、0dB を 1 にした目盛り
    static func meter(_ peak: Float) -> Double {
        guard peak > 0 else { return 0 }
        return max(0, min(1, 1 + Double(20 * log10(peak)) / 60))
    }
}

/// Mac から出ている音とマイクを同時に録る。
/// 仮想オーディオデバイスも出力先の切り替えも要らない（ScreenCaptureKit が OS から直接受け取る）。
/// 内部の状態は専用の直列キューの上でだけ触る（だから @unchecked Sendable）。
/// 例外は system / mic の2つで、start() で一度だけ作ってからは差し替えない（takeLevels が主スレッドから読む）。
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let systemFile = "system.wav"
    static let micFile = "mic.wav"

    /// 自分で止めていないのに録音が止まったとき（スリープ・権限の取り消しなど）に呼ばれる。
    var onInterrupted: ((Error) -> Void)?
    /// 最初に書き込みに失敗したとき、主スレッドで1回だけ呼ばれる（録音は続く）。
    var onWriteError: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "io.github.kumabeam.tsugumi.recorder")
    private let discardQueue = DispatchQueue(label: "io.github.kumabeam.tsugumi.recorder.video")
    private var stream: SCStream?
    private var system: TrackWriter?
    private var mic: TrackWriter?
    private var origin: CMTime?
    private var wallStart: CFTimeInterval = 0
    private var stopping = false
    private var finished = false
    private var writeError: Error?

    /// - Parameter microphoneID: 使うマイク。nil なら macOS の「サウンド」設定で選ばれているもの
    func start(folder: URL, microphoneID: String? = nil) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw TsugumiError.message("ディスプレイが見つかりません")
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.captureMicrophone = true
        if let microphoneID { configuration.microphoneCaptureDeviceID = microphoneID }
        // 映像は使わないので最小にする（音声だけの指定はできない）
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false

        system = try TrackWriter(url: folder.appendingPathComponent(Self.systemFile))
        mic = try TrackWriter(url: folder.appendingPathComponent(Self.micFile))

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: discardQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    /// 直近の音量（相手 = Mac から出た音、自分 = マイク）。1秒おきに読む前提
    func takeLevels() -> AudioLevels {
        AudioLevels(system: system?.takePeak() ?? 0, mic: mic?.takePeak() ?? 0)
    }

    /// 録音を止めてファイルを閉じる。書き込み中にエラーがあれば返す。
    @discardableResult
    func stop() async -> Error? {
        stopping = true
        if let stream { try? await stream.stopCapture() }
        stream = nil
        return await finish()
    }

    private func finish() async -> Error? {
        await withCheckedContinuation { continuation in
            queue.async {
                if !self.finished {
                    self.finished = true
                    // 2トラックの長さを揃えてから閉じる
                    let frames = max(self.system?.wav.frames ?? 0, self.mic?.wav.frames ?? 0)
                    for track in [self.system, self.mic] {
                        do {
                            try track?.padToLength(frames: frames)
                            try track?.wav.close()
                        } catch {
                            if self.writeError == nil { self.writeError = error }
                        }
                    }
                }
                continuation.resume(returning: self.writeError)
            }
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let track: TrackWriter?
        switch type {
        case .audio: track = system
        case .microphone: track = mic
        default: return
        }
        guard !finished, let track, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let now = CACurrentMediaTime()
        if origin == nil {
            origin = sampleBuffer.presentationTimeStamp
            wallStart = now
        }
        guard let origin else { return }
        do {
            try track.append(sampleBuffer, origin: origin, elapsed: now - wallStart)
        } catch {
            if writeError == nil {
                writeError = error
                DispatchQueue.main.async { self.onWriteError?(error) }
            }
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !stopping else { return }
        stopping = true
        self.stream = nil
        Task {
            _ = await self.finish()
            DispatchQueue.main.async { self.onInterrupted?(error) }
        }
    }
}
