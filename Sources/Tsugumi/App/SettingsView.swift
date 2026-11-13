import SwiftUI
import UserNotifications

/// 設定ウィンドウの中身の状態。
@MainActor
final class SettingsModel: ObservableObject {
    @Published var microphones: [Microphone] = []
    @Published var systemDefaultName: String?
    /// nil = macOS の設定に従う
    @Published var selectedMicrophoneID: String? {
        didSet {
            // 読み直し中は書かない。選んだマイクが今つながっていないだけで、記憶を消してしまわないように
            guard !loading, selectedMicrophoneID != oldValue else { return }
            Microphones.select(id: selectedMicrophoneID)
            microphoneChanged()
        }
    }
    /// マイクを選び直したあと（音量表示を新しいマイクに切り替えるため）
    var microphoneChanged: () -> Void = {}
    private var loading = false
    @Published var baseFolder: URL
    /// 録音中はマイクを変えられない
    @Published var isRecording = false
    /// macOS 側で Tsugumi の通知が許可されていない（会議の検知も文字起こしの完了も届かない）
    @Published var notificationsDenied = false

    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "開発版"
    var changeBaseFolder: () -> Void = {}
    var checkForUpdates: () -> Void = {}

    init(baseFolder: URL) {
        self.baseFolder = baseFolder
    }

    /// ウィンドウを出すたびに、つながっているマイクを読み直す
    func refresh() {
        loading = true
        defer { loading = false }
        microphones = Microphones.available()
        systemDefaultName = Microphones.systemDefault()?.name
        selectedMicrophoneID = Microphones.selected()?.id
        refreshNotifications()
    }

    /// 通知の許可状態を読み直す。システム設定で変えたらすぐ映るよう、画面を出している間は繰り返し呼ぶ
    func refreshNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let denied = settings.authorizationStatus == .denied
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self.notificationsDenied != denied { self.notificationsDenied = denied }
                }
            }
        }
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @AppStorage("detectMeetings") private var detectMeetings = true
    @AppStorage("autoTranscribe") private var autoTranscribe = false
    @AppStorage(Appearance.key) private var appearance = Appearance.system

    var body: some View {
        Form {
            Section("外観") {
                Picker("テーマ", selection: $appearance) {
                    ForEach(Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { Appearance.apply() }
            }
            Section("録音") {
                Picker("マイク", selection: $model.selectedMicrophoneID) {
                    Text("macOS の設定に従う" + (model.systemDefaultName.map { "（\($0)）" } ?? ""))
                        .tag(String?.none)
                    Divider()
                    ForEach(model.microphones, id: \.id) { microphone in
                        Text(microphone.name).tag(Optional(microphone.id))
                    }
                }
                .disabled(model.isRecording)
                if model.isRecording {
                    Text("録音中は変えられません").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("会議の開始を検知して知らせる", isOn: $detectMeetings)
            }
            Section("通知") {
                LabeledContent("macOS の通知") {
                    HStack {
                        if model.notificationsDenied {
                            Text("許可されていません").foregroundStyle(.orange)
                        } else {
                            Text("許可").foregroundStyle(.secondary)
                        }
                        Button("システム設定を開く") { model.openNotificationSettings() }
                    }
                }
            }
            Section("文字起こし") {
                Toggle("録音が終わったら自動で始める", isOn: $autoTranscribe)
            }
            Section("保存先") {
                LabeledContent("フォルダ") {
                    HStack {
                        Text(model.baseFolder.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("変更…") { model.changeBaseFolder() }
                    }
                }
            }
            Section("アップデート") {
                LabeledContent("バージョン", value: model.version)
                Button("アップデートを確認…") { model.checkForUpdates() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                model.refreshNotifications()
            }
        }
    }
}
