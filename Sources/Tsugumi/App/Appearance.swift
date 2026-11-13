import AppKit

/// 見た目の明暗。設定で「システムに従う／ライト／ダーク」から選ぶ
enum Appearance: String, CaseIterable {
    case system, light, dark

    static let key = "appearance"

    var title: String {
        switch self {
        case .system: "システム"
        case .light: "ライト"
        case .dark: "ダーク"
        }
    }

    private var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// 保存されている選択をアプリ全体に反映する。起動時と、設定で変えたときに呼ぶ
    @MainActor
    static func apply() {
        let saved = UserDefaults.standard.string(forKey: key).flatMap(Appearance.init(rawValue:)) ?? .system
        NSApp.appearance = saved.nsAppearance
    }
}
