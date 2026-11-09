import AVFoundation

struct Microphone: Equatable {
    let id: String
    let name: String
}

/// 録音に使うマイクの一覧と、選んだマイクの記憶。
enum Microphones {
    private static let selectionKey = "microphoneID"

    static func available() -> [Microphone] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
            .devices
            .map { Microphone(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// macOS の「サウンド」設定で選ばれているマイク。
    static func systemDefault() -> Microphone? {
        AVCaptureDevice.default(for: .audio).map { Microphone(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// メニューで選んであるマイク。未選択、または今つながっていなければ nil（macOS の設定に従う）。
    static func selected() -> Microphone? {
        guard let id = UserDefaults.standard.string(forKey: selectionKey) else { return nil }
        return available().first { $0.id == id }
    }

    /// 次の録音で実際に使われるマイク。
    static func current() -> Microphone? {
        selected() ?? systemDefault()
    }

    static func select(id: String?) {
        UserDefaults.standard.set(id, forKey: selectionKey)
    }
}
