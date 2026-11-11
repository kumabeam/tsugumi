import SwiftUI

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
        }
    }
    private var loading = false
    @Published var baseFolder: URL
    /// 録音中はマイクを変えられない
    @Published var isRecording = false

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
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @AppStorage("detectMeetings") private var detectMeetings = true

    var body: some View {
        Form {
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
                Text("ほかのアプリがマイクを使い始めたら通知します。クリックすると録音が始まります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Text("会議ごとにフォルダができ、文字起こしと聞き返し用の音声が入ります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("アップデート") {
                LabeledContent("バージョン", value: model.version)
                Button("アップデートを確認…") { model.checkForUpdates() }
                Text("1日1回、自動でも確認します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
