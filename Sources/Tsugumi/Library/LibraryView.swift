import SwiftUI
import UniformTypeIdentifiers

/// 録音一覧ウィンドウ。左に一覧、右に文字起こしと再生。
struct LibraryView: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 380)
        } detail: {
            if let item = model.selectedItem {
                Detail(model: model, player: model.player, item: item)
                    .id(item.id)
            } else {
                ContentUnavailableView {
                    Label("録音がありません", systemImage: "waveform")
                } description: {
                    Text("左下の赤いボタンで録音を始めます。\n音声や動画のファイルを一覧にドロップしても文字起こしできます。")
                }
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}

// MARK: - 左：一覧

private struct Sidebar: View {
    @ObservedObject var model: LibraryModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            List(model.filtered, selection: $model.selection) { item in
                Row(item: item, transcribingProgress: model.transcribingID == item.id ? model.progress : nil)
            }
            .overlay {
                if model.filtered.isEmpty, !model.search.isEmpty {
                    Text("見つかりません").foregroundStyle(.secondary)
                }
            }
            if let status = model.modelStatus {
                Divider()
                ModelBanner(text: status, failed: model.modelFailed, retry: model.actions.retryModelDownload)
            }
            Divider()
            RecordBar(model: model)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.actions.importFiles([url]) }
                }
            }
            return true
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("タイトル、文字起こし", text: $model.search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .background {
                    // ⌥⌘F で一覧の検索欄へ
                    Button("") { searchFocused = true }
                        .keyboardShortcut("f", modifiers: [.command, .option])
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            if !model.search.isEmpty {
                Button {
                    model.search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("検索を消す")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

private struct Row: View {
    let item: LibraryModel.Item
    /// 文字起こし中なら進み具合（%）
    let transcribingProgress: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title)
                .fontWeight(.semibold)
                .lineLimit(1)
            HStack {
                Text(item.dateText)
                Spacer()
                status
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var status: some View {
        switch item.session.meta.status {
        case .recording:
            Text("録音中").foregroundStyle(.red)
        case .recorded:
            if let transcribingProgress {
                Text("文字起こし \(transcribingProgress)%")
            } else {
                Text("順番待ち")
            }
        case .failed:
            Label("失敗", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled:
            Text("中止")
        case .done:
            Text(Format.length(item.session.meta.durationSeconds ?? 0)).monospacedDigit()
        }
    }
}

/// 文字起こしモデルのダウンロード状況（初回だけ出る）
private struct ModelBanner: View {
    let text: String
    let failed: Bool
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if failed {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
            if failed {
                Button("やり直す", action: retry).controlSize(.small)
            } else {
                Text("録音はこの間もできます。文字起こしは準備が済んでから始まります。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct RecordBar: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        HStack(spacing: 10) {
            Button(action: model.actions.toggleRecording) {
                ZStack {
                    Circle()
                        .strokeBorder(.secondary.opacity(0.6), lineWidth: 2)
                        .frame(width: 44, height: 44)
                    if model.recordingSince != nil {
                        RoundedRectangle(cornerRadius: 4).fill(.red).frame(width: 18, height: 18)
                    } else {
                        Circle().fill(.red).frame(width: 34, height: 34)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(model.recordingSince == nil ? "録音を開始（⌃⌥⌘R）" : "録音を停止（⌃⌥⌘R）")

            if let since = model.recordingSince {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Format.clock(context.date.timeIntervalSince(since)))
                        .font(.title3.monospacedDigit())
                        .lineLimit(1)
                        .fixedSize()
                }
                LevelMeters(levels: model.levels)
            }
        }
        // 右端の「⋯」と重ならないようにする
        .padding(.trailing, 32)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .overlay(alignment: .trailing) {
            MenuButton(action: model.actions.showMenu)
                .help("メニュー（メニューバーのアイコンと同じ操作）")
                .padding(.trailing, 12)
        }
    }
}

/// 録音中の音量。相手（Mac から出た音）と自分（マイク）を別々に出す。
/// 音が届いていないことに、会議の最中に気づくためのもの
private struct LevelMeters: View {
    let levels: AudioLevels

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("相手", levels.system)
            row("自分", levels.mic)
        }
        .fixedSize()
        .help("この1秒間の音量。長く振れないときは、マイクの選択や音の出力先を確認してください")
    }

    private func row(_ label: String, _ peak: Float) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(peak > 0.005 ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: max(3, 56 * AudioLevels.meter(peak)))
            }
            .frame(width: 56, height: 6)
            .animation(.linear(duration: 0.2), value: peak)
        }
    }
}

/// 「⋯」ボタン。押すとメニューバーと同じメニューがその場に出る。
/// メニューを出す位置に AppKit のビューが要るので、SwiftUI の Button ではなく NSButton を使う
private struct MenuButton: NSViewRepresentable {
    let action: (NSView) -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "メニュー")!,
                              target: context.coordinator, action: #selector(Coordinator.pressed(_:)))
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        button.imageScaling = .scaleProportionallyUpOrDown
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: (NSView) -> Void
        init(action: @escaping (NSView) -> Void) { self.action = action }
        @objc func pressed(_ sender: NSButton) { action(sender) }
    }
}

// MARK: - 右：文字起こしと再生

private struct Detail: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var player: PlayerModel
    let item: LibraryModel.Item

    @State private var title = ""
    @State private var copied = false
    @State private var confirmingDelete = false
    /// 検索で今見ている一致（matches の何番目か）
    @State private var matchPosition = 0
    /// 検索で飛ぶ先の行
    @State private var jumpTarget: Int?
    @FocusState private var titleFocused: Bool
    @FocusState private var findFocused: Bool

    /// 検索語を含む行
    private var matches: [Int] {
        let query = model.highlightQuery
        guard !query.isEmpty else { return [] }
        return model.lines.filter { TextSearch.contains($0.text, query) }.map(\.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.isFinding, item.session.meta.status == .done {
                Divider()
                findBar
            }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if item.session.meta.status == .done {
                Divider()
                PlayerBar(player: player)
            }
        }
        .onAppear {
            title = item.title
            // 一覧の検索から来たときは、最初に見つかった行へ
            jumpTarget = matches.first
        }
        .onChange(of: model.highlightQuery) { _, _ in
            matchPosition = 0
            jumpTarget = matches.first
        }
        .background { shortcuts }
        .onChange(of: titleFocused) { _, focused in
            if !focused { commitTitle() }
        }
        .confirmationDialog("「\(item.title)」をゴミ箱に入れますか？", isPresented: $confirmingDelete) {
            Button("ゴミ箱に入れる", role: .destructive) { model.moveToTrash(item) }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("録音と文字起こしがゴミ箱に移動します。Finder のゴミ箱から戻せます。")
        }
    }

    private func commitTitle() {
        model.rename(item, to: title)
    }

    // MARK: 文字起こしの中の検索

    private func openFind() {
        guard item.session.meta.status == .done else { return }
        model.isFinding = true
        findFocused = true
    }

    private func closeFind() {
        model.isFinding = false
        findFocused = false
    }

    /// 次（+1）／前（-1）の一致へ移る。端まで行ったら反対側に回る
    private func step(_ direction: Int) {
        let found = matches
        guard !found.isEmpty else { return }
        matchPosition = (matchPosition + direction + found.count) % found.count
        jumpTarget = found[matchPosition]
    }

    private var findBar: some View {
        let found = matches
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("文字起こしの中を検索", text: $model.findText)
                .textFieldStyle(.plain)
                .focused($findFocused)
                .onSubmit {
                    step(1)
                    findFocused = true
                }
            if !model.highlightQuery.isEmpty {
                Text(found.isEmpty ? "見つかりません" : "\(min(matchPosition, found.count - 1) + 1) / \(found.count) 行")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .help("前へ（⇧⌘G）")
                .disabled(found.isEmpty)
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .help("次へ（⌘G）")
                .disabled(found.isEmpty)
            Button("完了") { closeFind() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    /// 画面には出さない、キー操作だけのボタン
    private var shortcuts: some View {
        Group {
            Button("") { openFind() }.keyboardShortcut("f", modifiers: .command)
            Button("") { step(1) }.keyboardShortcut("g", modifiers: .command)
            Button("") { step(-1) }.keyboardShortcut("g", modifiers: [.command, .shift])
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("タイトル", text: $title)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.bold))
                    .focused($titleFocused)
                    .onSubmit {
                        commitTitle()
                        titleFocused = false
                    }
                Text(details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if item.session.meta.status == .done {
                Button {
                    model.copyTranscript(of: item)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "コピーしました" : "文字起こしをコピー", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
            Button {
                model.revealInFinder(item)
            } label: {
                Image(systemName: "folder")
            }
            .help("Finder で表示")

            Button {
                confirmingDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .help("ゴミ箱に入れる")
            .disabled(item.session.meta.status == .recording || model.transcribingID == item.id)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var details: String {
        var parts = [item.dateText]
        if let seconds = item.session.meta.durationSeconds { parts.append(TranscriptFormatter.durationText(seconds)) }
        if let microphone = item.session.meta.microphone { parts.append(microphone) }
        return parts.joined(separator: "・")
    }

    @ViewBuilder
    private var content: some View {
        switch item.session.meta.status {
        case .done:
            if model.lines.isEmpty {
                Text("文字起こしに発言がありませんでした").foregroundStyle(.secondary)
            } else {
                Transcript(
                    lines: model.lines, player: player,
                    query: model.highlightQuery, jumpTarget: jumpTarget
                )
            }
        case .recording:
            VStack(spacing: 10) {
                Image(systemName: "record.circle.fill").font(.largeTitle).foregroundStyle(.red)
                Text("録音中です。止めると文字起こしが始まります。").foregroundStyle(.secondary)
            }
        case .recorded:
            VStack(spacing: 10) {
                if model.transcribingID == item.id {
                    ProgressView(value: Double(model.progress), total: 100).frame(width: 220)
                    Text("文字起こし中 \(model.progress)%").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                    Text(model.modelStatus == nil ? "文字起こしの順番を待っています" : "文字起こしモデルの準備を待っています")
                        .foregroundStyle(.secondary)
                }
                Button("中止") { model.actions.cancelTranscription(item.session) }
            }
        case .cancelled:
            VStack(spacing: 10) {
                Image(systemName: "stop.circle").font(.largeTitle).foregroundStyle(.secondary)
                Text("文字起こしを中止しました")
                Text("音声は残っています。").font(.callout).foregroundStyle(.secondary)
                Button("やり直す") { model.actions.retry(item.session) }
            }
        case .failed:
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                Text("文字起こしに失敗しました")
                Text(item.session.meta.error ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("やり直す") { model.actions.retry(item.session) }
            }
        }
    }
}

private struct Transcript: View {
    let lines: [TranscriptLine]
    @ObservedObject var player: PlayerModel
    /// 目立たせる検索語
    var query = ""
    /// 検索で今見ている行
    var jumpTarget: Int?

    /// いま再生している位置の行
    private var currentID: Int? {
        guard player.hasStarted else { return nil }
        return lines.last { $0.start <= player.currentTime + 0.05 }?.id
    }

    var body: some View {
        let current = currentID
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(lines) { line in
                        LineRow(line: line, isCurrent: line.id == current, query: query, isJumpTarget: line.id == jumpTarget)
                            .id(line.id)
                            .onTapGesture { player.seek(to: line.start, play: true) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: current) { _, new in
                // 再生に合わせて、読んでいる行が見える位置に来るよう送る
                guard let new, player.isPlaying else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(new, anchor: .center) }
            }
            .onChange(of: jumpTarget, initial: true) { _, new in
                guard let new else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }
}

private struct LineRow: View {
    let line: TranscriptLine
    let isCurrent: Bool
    var query = ""
    /// 検索で今見ている行か
    var isJumpTarget = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(TranscriptFormatter.timestamp(line.start))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            if let label = line.label {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(labelColor(label).opacity(0.18), in: Capsule())
            }
            Text(TextSearch.highlighted(line.text, query))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isCurrent ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            if isJumpTarget {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.orange, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .help("クリックでここから再生")
    }

    private func labelColor(_ label: String) -> Color {
        switch label {
        case "相手": return .blue
        case "自分": return .green
        default: return .gray
        }
    }
}

private struct PlayerBar: View {
    @ObservedObject var player: PlayerModel

    var body: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                in: 0...max(player.duration, 0.1)
            )
            HStack {
                Text(Format.clock(player.currentTime))
                Spacer()
                Text(Format.clock(player.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .overlay {
                HStack(spacing: 22) {
                    Button { player.skip(by: -15) } label: { Image(systemName: "gobackward.15") }
                        .help("15秒戻る")
                    Button { player.togglePlayback() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title)
                    }
                    .help(player.isPlaying ? "一時停止" : "再生")
                    Button { player.skip(by: 15) } label: { Image(systemName: "goforward.15") }
                        .help("15秒進む")
                }
                .buttonStyle(.plain)
                .font(.title2)
                .foregroundStyle(.primary)
            }
            .overlay(alignment: .trailing) {
                speedMenu.padding(.trailing, 52)
            }
            .padding(.bottom, 4)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .disabled(!player.isAvailable)
        .overlay(alignment: .top) {
            if !player.isAvailable {
                Text("この録音の音声ファイルが見つかりません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
    }
}

private extension PlayerBar {
    /// 再生速度の切り替え
    var speedMenu: some View {
        Menu {
            ForEach(PlayerModel.rates, id: \.self) { rate in
                Button {
                    player.setRate(rate)
                } label: {
                    if rate == player.rate {
                        Label(PlayerModel.label(for: rate), systemImage: "checkmark")
                    } else {
                        Text(PlayerModel.label(for: rate))
                    }
                }
            }
        } label: {
            Text(PlayerModel.label(for: player.rate))
                .font(.callout.monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.primary)
        .help("再生速度")
    }
}

/// 文字起こしの中の語探し。大文字小文字と全角半角の違いは無視する。
enum TextSearch {
    private static let options: String.CompareOptions = [.caseInsensitive, .widthInsensitive]

    static func contains(_ text: String, _ query: String) -> Bool {
        text.range(of: query, options: options) != nil
    }

    /// 一致した部分に色を付けた文字列を返す。
    static func highlighted(_ text: String, _ query: String) -> AttributedString {
        var result = AttributedString(text)
        guard !query.isEmpty else { return result }
        var start = text.startIndex
        while start < text.endIndex, let range = text.range(of: query, options: options, range: start..<text.endIndex) {
            if let lower = AttributedString.Index(range.lowerBound, within: result),
               let upper = AttributedString.Index(range.upperBound, within: result) {
                result[lower..<upper].backgroundColor = .yellow
                result[lower..<upper].foregroundColor = .black
            }
            start = range.upperBound
        }
        return result
    }
}

/// 時間の表示。
enum Format {
    /// 経過時間や再生位置（0:14、1:02:03）
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func length(_ seconds: Double) -> String { clock(seconds.rounded()) }
}
