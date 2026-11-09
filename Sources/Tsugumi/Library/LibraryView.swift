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
        case .done:
            Text(Format.length(item.session.meta.durationSeconds ?? 0)).monospacedDigit()
        }
    }
}

private struct RecordBar: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        HStack(spacing: 12) {
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
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
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
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if item.session.meta.status == .done {
                Divider()
                PlayerBar(player: player)
            }
        }
        .onAppear { title = item.title }
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
                Transcript(lines: model.lines, player: player)
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
                    Text("文字起こしの順番を待っています").foregroundStyle(.secondary)
                }
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
                        LineRow(line: line, isCurrent: line.id == current)
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
        }
    }
}

private struct LineRow: View {
    let line: TranscriptLine
    let isCurrent: Bool

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
            Text(line.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isCurrent ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
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
