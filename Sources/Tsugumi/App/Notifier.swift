import AppKit
import UserNotifications

/// macOS の通知を出す。通知をクリックしたときの動きもここで受ける。
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let startAction = "start-recording"
    private static let meetingCategory = "meeting-detected"
    private static let folderKey = "folder"

    /// 「会議を検知」の通知がクリックされたとき
    var onStartRequested: (() -> Void)?

    /// .app として起動していないとき（開発中のコマンド実行など）は通知を使えない
    private let available = Bundle.main.bundleIdentifier != nil
    private var center: UNUserNotificationCenter? { available ? .current() : nil }

    func setUp() {
        guard let center else { return }
        center.delegate = self
        let start = UNNotificationAction(identifier: Self.startAction, title: "録音する", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.meetingCategory, actions: [start], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(title: String, body: String, openFolder: URL? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let openFolder { content.userInfo = [Self.folderKey: openFolder.path] }
        post(content)
    }

    func notifyMeetingDetected() {
        let content = UNMutableNotificationContent()
        content.title = "会議が始まったようです"
        content.body = "クリックすると録音を始めます。"
        content.categoryIdentifier = Self.meetingCategory
        post(content)
    }

    private func post(_ content: UNMutableNotificationContent) {
        center?.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        let folder = content.userInfo[Self.folderKey] as? String
        let isMeeting = content.categoryIdentifier == Self.meetingCategory
        let dismissed = response.actionIdentifier == UNNotificationDismissActionIdentifier
        await MainActor.run {
            if isMeeting {
                if !dismissed { self.onStartRequested?() }
            } else if let folder {
                NSWorkspace.shared.open(URL(fileURLWithPath: folder))
            }
        }
    }
}
