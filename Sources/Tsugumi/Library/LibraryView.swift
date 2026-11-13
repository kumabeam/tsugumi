import SwiftUI
import UniformTypeIdentifiers

/// 録音一覧ウィンドウ。左に一覧、右に文字起こしと再生。
struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    @State private var dropTargeted = false

    var body: some View {
        // NavigationSplitView はタイトルバーにサイドバー開閉ボタンを作るので、素の分割ビューを使う
        HSplitView {
            Sidebar(model: model)
                .frame(minWidth: 280, idealWidth: 280, maxWidth: 380)
            // Group だと選択の有無で子が入れ替わり、分割ビューの幅が戻る。ZStack で同じ子に保つ
            ZStack {
                if let item = model.selectedItem {
                    // ここで .id(item.id) を付けると分割ビューの子が作り直され、サイドバーの幅が元に戻ってしまう
                    Detail(model: model, player: model.player, item: item)
                } else {
                    ContentUnavailableView("録音がありません", systemImage: "waveform")
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 480)
        // ウィンドウのどこに落としても文字起こしする
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            // 全部そろってから1回で渡す（対応していないファイルの警告を1つにまとめるため）
            let collected = Locked<[URL]>([])
            let group = DispatchGroup()
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { collected.withValue { $0.append(url) } }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                let urls = collected.withValue { $0 }
                if !urls.isEmpty { model.actions.importFiles(urls) }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                ZStack {
                    Rectangle().fill(.background.opacity(0.85))
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                }
                .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - 左：一覧

private struct Sidebar: View {
    @ObservedObject var model: LibraryModel
    @FocusState private var searchFocused: Bool
    /// ダブルクリックでタイトルを打ち直している行
    @State private var editingID: String?

    var body: some View {
        VStack(spacing: 0) {
            searchField
            ScrollViewReader { proxy in
                List(model.filtered, selection: $model.selection) { item in
                    Row(
                        item: item,
                        transcribingProgress: model.transcribingID == item.id ? model.progress : nil,
                        isPending: model.isPending(item),
                        isEditing: editingID == item.id,
                        rename: { model.rename(item, to: $0) },
                        endEditing: { editingID = nil }
                    )
                }
                .listStyle(.sidebar)
                // 右クリックとダブルクリック。行の中に onTapGesture を置くと1クリックの選択を邪魔するので、List に付ける
                .contextMenu(forSelectionType: String.self) { ids in
                    if let item = model.items.first(where: { $0.id == ids.first }) {
                        if model.isPending(item) {
                            Button("文字起こし") { model.actions.transcribe(item.session) }
                        }
                        Button("名前を変更") { editingID = item.id }
                        Button("ゴミ箱に入れる") { model.pendingDelete = item }
                            .disabled(!model.canDelete(item))
                    }
                } primaryAction: { ids in
                    editingID = ids.first
                }
                // 録音開始やドロップで先頭に行が増えると、表示位置が元の行に合ったままで新しい行が検索欄の下に隠れる
                .onChange(of: model.filtered.first?.id) { _, first in
                    if let first { proxy.scrollTo(first, anchor: .top) }
                }
            }
            // ⌘⌫ は AppDelegate のキー監視が受けて pendingDelete に入れる（SwiftUI のショートカットにすると
            // 文字入力中の ⌘⌫ まで奪ってしまうため）
            .confirmationDialog(
                "「\(model.pendingDelete?.title ?? "")」をゴミ箱に入れますか？",
                isPresented: Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } }),
                presenting: model.pendingDelete
            ) { item in
                Button("ゴミ箱に入れる", role: .destructive) { model.moveToTrash(item) }
                Button("キャンセル", role: .cancel) {}
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
    /// 録音は終わっているが、文字起こしをまだ頼んでいない
    let isPending: Bool
    /// ダブルクリックされて、タイトルを打ち直している最中か
    let isEditing: Bool
    /// タイトルを打ち直したとき
    let rename: (String) -> Void
    let endEditing: () -> Void

    @State private var draft = ""
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if isEditing {
                // Return で決定、esc でやめる
                TextField("タイトル", text: $draft)
                    .textFieldStyle(.plain)
                    .fontWeight(.semibold)
                    .focused($editorFocused)
                    .onSubmit { finishEditing(commit: true) }
                    .onExitCommand { finishEditing(commit: false) }
                    .onChange(of: editorFocused) { _, focused in
                        if !focused { finishEditing(commit: true) }
                    }
                    .onAppear { draft = item.title }
                    // 出た直後はまだウィンドウに入っていないことがあるので、一拍おいてフォーカスする
                    .task { editorFocused = true }
            } else {
                Text(item.title)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
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

    private func finishEditing(commit: Bool) {
        guard isEditing else { return }
        // 変えていないのに保存すると、自動の名前が本物のタイトルとして残ってしまう
        if commit, draft != item.title { rename(draft) }
        endEditing()
    }

    @ViewBuilder
    private var status: some View {
        switch item.session.meta.status {
        case .recording:
            Text("録音中").foregroundStyle(.red)
        case .recorded:
            if let transcribingProgress {
                Text("文字起こし \(transcribingProgress)%")
            } else if isPending {
                Text("文字起こし前").fontWeight(.semibold).foregroundStyle(.orange)
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

            if let since = model.recordingSince {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Format.clock(context.date.timeIntervalSince(since)))
                        .font(.title3.monospacedDigit())
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            LevelMeters(model: model.levels)
        }
        // 両端のボタンと重ならないようにする
        .padding(.leading, 48)
        .padding(.trailing, 32)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .overlay(alignment: .leading) {
            microphoneMenu
        }
        .overlay(alignment: .trailing) {
            Button(action: model.actions.chooseFiles) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
        }
    }

    /// 使うマイクの切り替え。設定（⌘,）と同じ内容を、録音を始める場所から直接選べるようにする
    private var microphoneMenu: some View {
        UpwardMenu(name: "マイク", items: microphoneItems) {
            HStack(spacing: 3) {
                Image(systemName: "mic").font(.system(size: 17))
                Image(systemName: "chevron.up").font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 12)
            .padding(.trailing, 6)
        }
    }

    /// 開くたびに、その時つながっているマイクで作る
    private func microphoneItems() -> [PopUpItem] {
        let recording = model.recordingSince != nil
        let available = Microphones.available()
        let selected = Microphones.selectedID.flatMap { id in available.first { $0.id == id }?.id }
        let systemName = Microphones.systemDefault()?.name
        var items: [PopUpItem] = [
            .entry("macOS の設定に従う" + (systemName.map { "（\($0)）" } ?? ""), checked: selected == nil, enabled: !recording) {
                model.actions.selectMicrophone(nil)
            },
            .separator,
        ]
        items += available.map { microphone in
            .entry(microphone.name, checked: microphone.id == selected, enabled: !recording) {
                model.actions.selectMicrophone(microphone.id)
            }
        }
        if recording {
            items += [.separator, .entry("録音中は変えられません", enabled: false) {}]
        }
        return items
    }
}

/// 相手（Mac から出る音）と自分（マイク）の音量。録音前から出して、音が入っているかを録音を始める前に確かめられるようにする
private struct LevelMeters: View {
    @ObservedObject var model: LevelsModel

    var body: some View {
        if model.isLive {
            VStack(alignment: .leading, spacing: 4) {
                row("相手", model.current.system)
                row("自分", model.current.mic)
            }
            .fixedSize()
        }
    }

    private func row(_ label: String, _ peak: Float) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                // 幅ではなく拡大率を変える。レイアウトをやり直さずに済むので、0.1 秒おきに動かしても軽い
                Rectangle()
                    .fill(peak > 0.005 ? Color.green : Color.secondary.opacity(0.4))
                    .scaleEffect(x: max(3 / 48, AudioLevels.meter(peak)), anchor: .leading)
            }
            .frame(width: 48, height: 6)
            .clipShape(Capsule())
            .animation(.linear(duration: 0.1), value: peak)
        }
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
    /// タイトルを打ち始めたときの録音の id。別の録音に切り替えた直後にフォーカスが外れても、元の録音に書く
    @State private var editingTitleOf: String?
    /// jumpTarget がどの録音のものか（録音を切り替えた直後に、前の録音の行へ飛ばないため）
    @State private var jumpFor: String?

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
                // 録音を切り替えたら、文字起こしのスクロール位置を頭に戻す
                .id(item.id)
            if LibraryModel.playableAudio(of: item.session) != nil {
                Divider()
                PlayerBar(player: player)
            }
        }
        .onAppear {
            title = item.title
            // 一覧の検索から来たときは、最初に見つかった行へ
            jump(to: matches.first)
        }
        .onChange(of: item.id) { _, _ in
            // 別の録音に切り替わった。ビューは作り直さない（分割ビューの幅が戻るため）ので、状態をここで戻す
            commitTitle()
            titleFocused = false
            title = item.title
            copied = false
            confirmingDelete = false
            matchPosition = 0
            jump(to: matches.first)
        }
        .onChange(of: model.highlightQuery) { _, _ in
            matchPosition = 0
            jump(to: matches.first)
        }
        .background { shortcuts }
        .onChange(of: titleFocused) { _, focused in
            if focused { editingTitleOf = item.id } else { commitTitle() }
        }
        .onChange(of: item.title) { _, new in
            // 一覧側で名前を変えたら、こちらの表示も合わせる（打っている最中は触らない）
            if !titleFocused, editingTitleOf == nil { title = new }
        }
        .confirmationDialog("「\(item.title)」をゴミ箱に入れますか？", isPresented: $confirmingDelete) {
            Button("ゴミ箱に入れる", role: .destructive) { model.moveToTrash(item) }
            Button("キャンセル", role: .cancel) {}
        }
    }

    private func commitTitle() {
        guard let id = editingTitleOf else { return }
        editingTitleOf = nil
        // 打ち始めたときの Item をそのまま使わない（その間に録音の状態が進んでいると、古い状態を書き戻してしまう）
        guard let target = model.items.first(where: { $0.id == id }), title != target.title else { return }
        model.rename(target, to: title)
    }

    private func jump(to line: Int?) {
        jumpFor = item.id
        jumpTarget = line
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
        jump(to: found[matchPosition])
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
                .disabled(found.isEmpty)
            Button { step(1) } label: { Image(systemName: "chevron.down") }
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
                        .frame(minWidth: 150)
                }
                .buttonStyle(.borderedProminent)
            }
            Button {
                model.revealInFinder(item)
            } label: {
                Image(systemName: "folder").frame(minWidth: 24)
            }

            Button {
                confirmingDelete = true
            } label: {
                Image(systemName: "trash").frame(minWidth: 24)
            }
            .disabled(!model.canDelete(item))
        }
        .controlSize(.large)
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
                    query: model.highlightQuery, jumpTarget: jumpFor == item.id ? jumpTarget : nil
                )
            }
        case .recording:
            VStack(spacing: 10) {
                Image(systemName: "record.circle.fill").font(.largeTitle).foregroundStyle(.red)
                Text("録音中").foregroundStyle(.secondary)
            }
        case .recorded:
            VStack(spacing: 10) {
                if model.isPending(item) {
                    Button {
                        model.actions.transcribe(item.session)
                    } label: {
                        Label("文字起こしを始める", systemImage: "text.quote")
                            .font(.title3)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
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
            }
        case .cancelled:
            VStack(spacing: 10) {
                Image(systemName: "stop.circle").font(.largeTitle).foregroundStyle(.secondary)
                Text("文字起こしを中止しました")
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
                    Button { player.togglePlayback() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title)
                    }
                    Button { player.skip(by: 15) } label: { Image(systemName: "goforward.15") }
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
        UpwardMenu(name: "再生速度", items: {
            PlayerModel.rates.map { rate in
                .entry(PlayerModel.label(for: rate), checked: rate == player.rate) { player.setRate(rate) }
            }
        }) {
            HStack(spacing: 3) {
                Text(PlayerModel.label(for: player.rate))
                    .font(.callout.monospacedDigit())
                Image(systemName: "chevron.up").font(.caption2.weight(.semibold))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
        }
        .fixedSize()
        .foregroundStyle(.primary)
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
