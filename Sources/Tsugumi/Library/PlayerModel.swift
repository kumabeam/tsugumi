import AVFoundation
import Combine

/// 録音の再生。再生位置を画面に伝える。
@MainActor
final class PlayerModel: ObservableObject {
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    /// 再生できる音声があるか
    @Published private(set) var isAvailable = false
    /// 一度でも再生や頭出しをしたか（していない間は、どの行も「再生中」として光らせない）
    @Published private(set) var hasStarted = false

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    func load(_ url: URL?) {
        unload()
        guard let url else { return }

        let player = AVPlayer(url: url)
        self.player = player
        isAvailable = true

        let interval = CMTime(value: 1, timescale: 5)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.seconds.isFinite else { return }
                self.currentTime = time.seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
        Task {
            guard let asset = player.currentItem?.asset,
                  let length = try? await asset.load(.duration), length.seconds.isFinite,
                  self.player === player else { return }
            self.duration = length.seconds
        }
    }

    private func unload() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        isAvailable = false
        hasStarted = false
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            pause()
        } else {
            // 最後まで再生し終えていたら頭から
            if duration > 0, currentTime >= duration - 0.2 { seek(to: 0) }
            player.play()
            isPlaying = true
            hasStarted = true
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func seek(to seconds: Double, play: Bool = false) {
        guard let player else { return }
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
        hasStarted = true
        if play {
            player.play()
            isPlaying = true
        }
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }
}
