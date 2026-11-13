import CoreAudio
import Foundation
import os

/// ほかのアプリ（Zoom・Teams・ブラウザの Meet など）がマイクを使い始めたことを検知する。
/// 会議アプリを個別に見張るのではなく「どれかのアプリがマイクから録り始めた」を合図にしている。
///
/// 装置ではなく、音声を使っているプロセスの一覧（macOS 14.2 から取れる）を見る。
/// 装置の「使用中」は再生だけでも立つので、ヘッドセットで音楽を流しただけで会議と間違える。
/// 既定のマイクだけを見る作りだと、会議アプリで別のマイクを選んでいる人には一度も反応しない。
///
/// 1秒おきに読んで比べる。プロセスの「マイク使用中」の変化通知（リスナー）は試したところ一度も
/// 届かなかったため（macOS 15.7、ボイスメモで確認）
final class MicActivityMonitor {
    /// 新しくマイクを使い始めたアプリがあったとき（その pid の集合）。空は「どのアプリも使っていない」。
    /// 「どれかが使っているか」の変化ではなく「新しく使い始めたアプリがあるか」で見る。
    /// Discord のようにマイクを開きっぱなしのアプリがいると、会議の開始が埋もれてしまうため
    var onChange: ((Set<pid_t>) -> Void)?

    /// いまマイクから録っているプロセス（自分は除く）
    private var running: Set<pid_t> = []
    private var timer: Timer?
    private let ownPID = getpid()
    private let log = Logger(subsystem: "io.github.kumabeam.tsugumi", category: "meeting")

    func start() {
        running = runningNow()
        log.notice("監視開始: プロセス \(Self.processObjects().count) 件、使用中 \(self.running.count) 件")
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.check()
        }
        timer?.tolerance = 0.5
    }

    /// このアプリたちが、まだマイクから録っているか（一瞬だけの使用を見分けるための再確認用）
    func isUsingInput(_ pids: Set<pid_t>) -> Bool {
        !runningNow().isDisjoint(with: pids)
    }

    private func runningNow() -> Set<pid_t> {
        Set(Self.processObjects().compactMap { process in
            guard Self.isRunningInput(process) else { return nil }
            let pid = Self.pid(process)
            guard pid > 0, pid != ownPID, !Self.isSystemCaptureDaemon(pid) else { return nil }
            return pid
        })
    }

    /// macOS の画面・音声取り込みの裏方（/usr/libexec/replayd）か。
    /// このアプリが音量を測ったり録ったりするたびにマイクを使い始めるので、会議アプリと間違えないよう外す。
    /// pid は使い回されるので覚えずに毎回見る（軽い呼び出しで、数は多くても毎秒数件）
    private static func isSystemCaptureDaemon(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return String(cString: buffer).hasSuffix("/replayd")
    }

    private func check() {
        let now = runningNow()
        defer { running = now }
        let started = now.subtracting(running)
        if !started.isEmpty {
            log.notice("マイクを使い始めた: \(started.sorted(), privacy: .public)（使用中 \(now.count)）")
            onChange?(started)
        } else if now.isEmpty, !running.isEmpty {
            log.notice("マイクの使用が全部止まった")
            onChange?([])
        }
    }

    // MARK: - CoreAudio

    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func pid(_ process: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid) == noErr else { return -1 }
        return pid
    }

    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running)
        return status == noErr && running != 0
    }
}
