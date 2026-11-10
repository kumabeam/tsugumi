import AppKit
import Sparkle

/// アプリ内アップデート（Sparkle）。
///
/// 起動時に appcast.xml（版の一覧）を見に行き、新しい版があれば知らせて入れ替える。
/// 更新の正しさは EdDSA の署名で確かめる（公開鍵は Info.plist の SUPublicEDKey）。
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!

    /// 動作確認用。別の appcast を見に行かせる（`-updateFeedURL http://localhost:8765/appcast.xml`）
    nonisolated static let feedOverrideKey = "updateFeedURL"
    /// 動作確認用。起動直後に確認を1回走らせる（`-checkUpdatesOnLaunch YES`）
    static let checkOnLaunchKey = "checkUpdatesOnLaunch"

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        if UserDefaults.standard.bool(forKey: Self.checkOnLaunchKey) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.check() }
        }
    }

    /// メニューの「アップデートを確認…」
    func check() {
        controller.checkForUpdates(nil)
    }

    var canCheck: Bool { controller.updater.canCheckForUpdates }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: Self.feedOverrideKey)
    }
}
