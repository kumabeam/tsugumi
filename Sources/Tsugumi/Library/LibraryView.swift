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
        .tint(Theme.accent)
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
                    .keyboardShortcut(.defaultAction)
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
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.body.weight(.semibold))
            TextField("タイトル、文字起こし", text: $model.search)
                .textFieldStyle(.plain)
                .font(.body)
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
        .padding(.horizontal, 14)
        .frame(height: Theme.controlHeight)
        .glassCapsule()
        .padding(.horizontal, 12)
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
            Text("録音中").foregroundStyle(Theme.live)
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
            RecordButton(recording: model.recordingSince != nil, size: 44, action: model.actions.toggleRecording)

            LevelMeters(model: model.levels)
        }
        // 両端のボタンと重ならないようにする
        .padding(.leading, 48)
        .padding(.trailing, 32)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .overlay(alignment: .leading) {
            microphoneControls
        }
        .overlay(alignment: .trailing) {
            GlassGroup {
                Button(action: model.actions.chooseFiles) { Image(systemName: "doc.badge.plus") }
            }
            .padding(.trailing, 12)
        }
    }

    /// マイクのアイコンはミュートの切り替え、隣の矢印は使うマイクの選択（設定（⌘,）と同じ内容）
    private var microphoneControls: some View {
        GlassGroup {
            Button(action: model.actions.toggleMute) {
                Image(systemName: model.isMuted ? "mic.slash" : "mic")
                    .foregroundStyle(model.isMuted ? Theme.live : Color.primary)
            }
            UpwardMenu(name: "マイク", items: microphoneItems) {
                Image(systemName: "chevron.up")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 26)
            }
        }
        .padding(.leading, 8)
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
    /// 同じ録音のフォルダ名が変わって id が変わっても、打っている名前をその録音に書くための印
    @State private var editingTitleStarted: Date?
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
                PlayerBar(player: player, peaks: model.waveformPeaks)
            }
        }
        .onAppear {
            title = item.title
            // 一覧の検索から来たときは、最初に見つかった行へ
            jump(to: matches.first)
        }
        .onChange(of: item.id) { old, _ in
            // 同じ録音のフォルダ名が変わっただけなら、打っている途中の名前はそのまま
            if editingTitleOf == old, editingTitleStarted == item.session.meta.startedAt {
                editingTitleOf = item.id
                return
            }
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
            if focused {
                editingTitleOf = item.id
                editingTitleStarted = item.session.meta.startedAt
            } else {
                commitTitle()
            }
        }
        .onChange(of: item.title) { _, new in
            // 一覧側で名前を変えたら、こちらの表示も合わせる（打っている最中は触らない）
            if !titleFocused, editingTitleOf == nil { title = new }
        }
        .confirmationDialog("「\(item.title)」をゴミ箱に入れますか？", isPresented: $confirmingDelete) {
            Button("ゴミ箱に入れる", role: .destructive) { model.moveToTrash(item) }
                .keyboardShortcut(.defaultAction)
            Button("キャンセル", role: .cancel) {}
        }
    }

    private func commitTitle() {
        guard let id = editingTitleOf else { return }
        let started = editingTitleStarted
        editingTitleOf = nil
        editingTitleStarted = nil
        // 打ち始めたときの Item をそのまま使わない（その間に録音の状態が進んでいると、古い状態を書き戻してしまう）。
        // フォルダ名が変わって id が見つからなければ、開始日時で同じ録音を探す
        let sameStart = model.items.filter { $0.session.meta.startedAt == started }
        let found = model.items.first(where: { $0.id == id }) ?? (sameStart.count == 1 ? sameStart.first : nil)
        guard let target = found, title != target.title else { return }
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
                .buttonStyle(GlassCapsuleButtonStyle(role: .regular))
            }
            GlassGroup {
                Button { model.revealInFinder(item) } label: { Image(systemName: "folder") }
                Button { confirmingDelete = true } label: { Image(systemName: "trash") }
                    .disabled(!model.canDelete(item))
            }
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
                    query: model.highlightQuery, jumpTarget: jumpFor == item.id ? jumpTarget : nil
                )
            }
        case .recording:
            // このアプリが録っている録音でなければ（別のプロセスの録音など）、手元の波形は別物なので出さない
            RecordingView(
                waveform: model.waveform,
                since: model.recordingSince,
                startedAt: item.session.meta.startedAt,
                stop: model.actions.toggleRecording
            )
        case .recorded:
            VStack(spacing: 10) {
                if model.isPending(item) {
                    Button {
                        model.actions.transcribe(item.session)
                    } label: {
                        Label("文字起こし", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(GlassCapsuleButtonStyle())
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
                        .buttonStyle(GlassCapsuleButtonStyle(role: .regular))
                        .padding(.top, 6)
                }
            }
        case .cancelled:
            VStack(spacing: 10) {
                Image(systemName: "stop.circle").font(.largeTitle).foregroundStyle(.secondary)
                Text("文字起こしを中止しました")
                Button("やり直す") { model.actions.retry(item.session) }
                    .buttonStyle(GlassCapsuleButtonStyle(role: .regular))
                    .padding(.top, 6)
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
                    .buttonStyle(GlassCapsuleButtonStyle(role: .regular))
                    .padding(.top, 6)
            }
        }
    }
}

// MARK: - 録音中の画面

/// ここまでの音の波形と経過時間。相手の音を上、自分の声を下に出す
private struct RecordingView: View {
    @ObservedObject var waveform: WaveformModel
    /// このアプリで録音中なら、その開始時刻
    let since: Date?
    let startedAt: Date
    let stop: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Waveform(peaks: since != nil ? waveform.peaks : [], since: since ?? startedAt)
                .frame(height: 220)
            Spacer()
            HStack {
                Spacer()
                RecordButton(recording: true, size: 56, action: stop)
                Spacer()
            }
            .overlay(alignment: .trailing) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Format.clock(context.date.timeIntervalSince(since ?? startedAt)))
                        .font(.system(size: 40, weight: .medium, design: .rounded).monospacedDigit())
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.trailing, 24)
            }
            .padding(.bottom, 24)
        }
    }
}

/// 録音の波形。中央の線が今で、左へ過去が流れる。1 本が 0.1 秒。
/// 位置は録音開始からの実時間で決めるので、音量の更新（0.1 秒おき）とは別に画面のリフレッシュごとに滑らかに動く
private struct Waveform: View {
    let peaks: [AudioLevels]
    let since: Date

    private static let barWidth: CGFloat = 2
    private static let step: CGFloat = 3
    private static let rulerHeight: CGFloat = 22
    private static let pointsPerSecond = step / WaveformModel.interval

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(since)
                let center = size.width / 2
                let wave = CGRect(x: 0, y: 0, width: size.width, height: size.height - Self.rulerHeight)
                let mid = wave.midY
                let reach = wave.height / 2 - 6
                func x(at seconds: TimeInterval) -> CGFloat { center - CGFloat(elapsed - seconds) * Self.pointsPerSecond }

                context.fill(
                    Path(CGRect(x: 0, y: mid - 0.5, width: size.width, height: 1)),
                    with: .color(.secondary.opacity(0.35))
                )

                // 左端から今までに入る本数だけ描く。いちばん新しい本は中央で切る
                let visibleSeconds = TimeInterval(center / Self.pointsPerSecond)
                let first = max(0, Int((elapsed - visibleSeconds) / WaveformModel.interval) - 1)
                var index = first
                while index < peaks.count {
                    let left = x(at: Double(index) * WaveformModel.interval)
                    if left >= center { break }
                    let width = min(Self.barWidth, center - left)
                    let peak = peaks[index]
                    let up = max(1, CGFloat(AudioLevels.meter(peak.system)) * reach)
                    let down = max(1, CGFloat(AudioLevels.meter(peak.mic)) * reach)
                    // 上が相手、下が自分。色では分けず、「今」の赤い線が埋もれないよう主色で描く
                    context.fill(
                        Path(roundedRect: CGRect(x: left, y: mid - up, width: width, height: up), cornerRadius: 1),
                        with: .color(Theme.accent)
                    )
                    context.fill(
                        Path(roundedRect: CGRect(x: left, y: mid, width: width, height: down), cornerRadius: 1),
                        with: .color(Theme.accent)
                    )
                    index += 1
                }

                // 目盛りは 1 秒ごと、時刻は 10 秒ごと。右側（これから）にも出す
                let firstSecond = max(0, Int((elapsed - visibleSeconds).rounded(.down)))
                let lastSecond = Int((elapsed + TimeInterval((size.width - center) / Self.pointsPerSecond)).rounded(.up))
                for seconds in firstSecond...max(firstSecond, lastSecond) {
                    let tickX = x(at: Double(seconds))
                    guard tickX >= 0, tickX <= size.width else { continue }
                    let tall = seconds % 10 == 0
                    context.fill(
                        Path(CGRect(x: tickX, y: wave.maxY + 2, width: 1, height: tall ? 6 : 3)),
                        with: .color(.secondary.opacity(0.5))
                    )
                    if tall {
                        context.draw(
                            Text(Format.clock(Double(seconds))).font(.caption2).foregroundStyle(.secondary),
                            at: CGPoint(x: tickX + 1, y: wave.maxY + 15), anchor: .center
                        )
                    }
                }

                // 今の位置
                context.fill(Path(CGRect(x: center - 1, y: wave.minY, width: 2, height: wave.height)), with: .color(Theme.live))
            }
        }
        .overlay(alignment: .topLeading) { Text("相手").font(.caption).foregroundStyle(.secondary).padding(.leading, 4) }
        .overlay(alignment: .bottomLeading) {
            Text("自分").font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 4).padding(.bottom, Self.rulerHeight)
        }
        .padding(.horizontal, 20)
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
        .background(isCurrent ? Theme.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            if isJumpTarget {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
    }

    private func labelColor(_ label: String) -> Color {
        switch label {
        case "相手": return Theme.partner
        case "自分": return Theme.me
        default: return .gray
        }
    }
}

private struct PlayerBar: View {
    @ObservedObject var player: PlayerModel
    let peaks: [AudioLevels]

    var body: some View {
        VStack(spacing: 4) {
            OverviewWaveform(peaks: peaks, position: player.currentTime, duration: player.duration) { player.seek(to: $0) }
                .frame(height: 44)
            HStack {
                Text("0:00")
                Spacer()
                Text(Format.clock(player.duration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            HStack(spacing: 22) {
                GlassGroup {
                    Button { player.skip(by: -15) } label: { Image(systemName: "gobackward.15") }
                    Button { player.togglePlayback() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    }
                    Button { player.skip(by: 15) } label: { Image(systemName: "goforward.15") }
                }
                Spacer()
                speedMenu
                Text(Format.clock(player.currentTime))
                    .font(.system(size: 28, weight: .medium, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .font(.title2)
            .foregroundStyle(.primary)
            .padding(.top, 4)
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

/// 録音全体の波形と再生位置。クリックやドラッグでその位置へ飛ぶ
private struct OverviewWaveform: View {
    let peaks: [AudioLevels]
    let position: Double
    let duration: Double
    let seek: (Double) -> Void

    private static let step: CGFloat = 3
    private static let barWidth: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            Canvas { context, size in
                let bars = max(1, Int(size.width / Self.step))
                let mid = size.height / 2
                let reach = mid - 2
                context.fill(
                    Path(CGRect(x: 0, y: mid - 0.5, width: size.width, height: 1)),
                    with: .color(.secondary.opacity(0.3))
                )
                guard !peaks.isEmpty else { return }
                // 横幅を音声の長さに割り当て、再生位置の線と同じ時間軸で描く
                let span = duration > 0 ? duration : Double(peaks.count) * WaveformFile.interval
                let playedBars = duration > 0 ? Int((position / duration * Double(bars)).rounded(.down)) : 0
                for bar in 0..<bars {
                    let from = Int(Double(bar) / Double(bars) * span / WaveformFile.interval)
                    let to = max(from + 1, Int(Double(bar + 1) / Double(bars) * span / WaveformFile.interval))
                    guard from < peaks.count else { break }
                    var up: Float = 0
                    var down: Float = 0
                    for index in from..<min(to, peaks.count) {
                        up = max(up, peaks[index].system)
                        down = max(down, peaks[index].mic)
                    }
                    let x = CGFloat(bar) * Self.step
                    let played = bar < playedBars
                    let upHeight = max(1, CGFloat(AudioLevels.meter(up)) * reach)
                    let downHeight = max(1, CGFloat(AudioLevels.meter(down)) * reach)
                    context.fill(
                        Path(CGRect(x: x, y: mid - upHeight, width: Self.barWidth, height: upHeight)),
                        with: .color(played ? Theme.played : Theme.remaining)
                    )
                    context.fill(
                        Path(CGRect(x: x, y: mid, width: Self.barWidth, height: downHeight)),
                        with: .color(played ? Theme.played : Theme.remaining)
                    )
                }
                if duration > 0 {
                    let x = CGFloat(position / duration) * size.width
                    context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(Theme.played))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    guard duration > 0 else { return }
                    seek(min(max(0, Double(value.location.x / width)), 1) * duration)
                }
            )
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
