import CoreAudio
import Foundation

/// ほかのアプリ（Zoom・Teams・ブラウザの Meet など）がマイクを使い始めたことを検知する。
/// 会議アプリを個別に見張るのではなく「マイクが使われ始めた」を合図にしている。
final class MicActivityMonitor {
    /// マイクの使用状態が変わったとき（true = 使われ始めた）
    var onChange: ((Bool) -> Void)?

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var lastState = false
    private let queue = DispatchQueue.main

    private var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var runningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private lazy var deviceChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.bindToDefaultInput()
    }
    private lazy var runningChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.check()
    }

    func start() {
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultInputAddress, queue, deviceChanged
        )
        bindToDefaultInput()
    }

    var isMicInUse: Bool {
        guard device != kAudioObjectUnknown else { return false }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &runningAddress, 0, nil, &size, &running)
        return status == noErr && running != 0
    }

    /// 既定のマイクが変わったら（AirPods をつないだ等）、見張る先を付け替える
    private func bindToDefaultInput() {
        if device != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(device, &runningAddress, queue, runningChanged)
        }
        var current = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultInputAddress, 0, nil, &size, &current
        )
        device = current
        if device != kAudioObjectUnknown {
            AudioObjectAddPropertyListenerBlock(device, &runningAddress, queue, runningChanged)
        }
        lastState = isMicInUse
    }

    private func check() {
        let state = isMicInUse
        guard state != lastState else { return }
        lastState = state
        onChange?(state)
    }
}
