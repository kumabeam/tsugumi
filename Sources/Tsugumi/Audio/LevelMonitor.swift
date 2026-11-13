import CoreMedia
import Foundation
import ScreenCaptureKit

/// 録音していないときに、相手の音とマイクの音量だけを測る。ファイルには何も書かない。
/// 録音一覧ウィンドウを開いている間だけ動かし、録音を始める前から「音が入っているか」を見せるためのもの。
/// 録音と同じ経路（ScreenCaptureKit）で受け取るので、ここで振れていれば録音でも入る
final class LevelMonitor: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// 自分で止めていないのに止まったとき（スリープ・権限の取り消しなど）、主スレッドで呼ばれる
    var onStopped: (() -> Void)?

    private let queue = DispatchQueue(label: "io.github.kumabeam.tsugumi.monitor")
    private let discardQueue = DispatchQueue(label: "io.github.kumabeam.tsugumi.monitor.video")
    private var stream: SCStream?
    private let system = Locked<Float>(0)
    private let mic = Locked<Float>(0)
    private let stopping = Locked(false)

    func start(microphoneID: String?) async throws {
        stream = try await Recorder.startStream(microphoneID: microphoneID, delegate: self, output: self, queue: queue, discardQueue: discardQueue)
    }

    /// 前回読んでからの最大振幅。0.1 秒おきに読む前提
    func takeLevels() -> AudioLevels {
        AudioLevels(
            system: system.withValue { value in defer { value = 0 }; return value },
            mic: mic.withValue { value in defer { value = 0 }; return value }
        )
    }

    /// 自分で止めたか、勝手に止まったか
    var isStopped: Bool { stopping.withValue { $0 } }

    func stop() async {
        stopping.withValue { $0 = true }
        if let stream { try? await stream.stopCapture() }
        stream = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let target: Locked<Float>
        switch type {
        case .audio: target = system
        case .microphone: target = mic
        default: return
        }
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
              let peak = try? TrackWriter.peak(of: sampleBuffer) else { return }
        target.withValue { $0 = max($0, peak) }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // stream はここでは触らない（stop() が主スレッド側で片付ける。止まった stream に stopCapture しても害はない）
        let wasStopping = stopping.withValue { value in defer { value = true }; return value }
        guard !wasStopping else { return }
        DispatchQueue.main.async { self.onStopped?() }
    }
}
