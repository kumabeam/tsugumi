import Foundation

/// 文字起こしモデル（約3GB）の置き場所と、初回のダウンロード。
///
/// アプリ本体に入れると配布物が巨大になるので、初回起動時にアプリ自身が取ってくる。
/// すでに持っている人（whisper.cpp を自分で使っている人）のものは、そのまま使う。
@MainActor
final class ModelStore {
    enum State: Equatable {
        case ready(URL)
        case downloading(received: Int64, total: Int64)
        case failed(String)
    }

    private(set) var state: State = .failed("まだ確認していません") {
        didSet { onChange?() }
    }
    /// 状態が変わったとき（表示の更新用）
    var onChange: (() -> Void)?
    /// モデルが使えるようになったとき（待っていた文字起こしを始める）
    var onReady: (() -> Void)?

    nonisolated static let modelFile = "ggml-large-v3.bin"
    nonisolated static let downloadURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin")!
    nonisolated static let preferenceKey = "whisperModel"

    /// アプリが自分で保存する場所
    nonisolated static var ownFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tsugumi", isDirectory: true)
    }

    /// 保存先。普段は ownFolder。動作確認で別の場所に落とすときだけ指定する
    private let folder: URL

    init(folder: URL? = nil) {
        self.folder = folder ?? Self.ownFolder
    }

    /// 使えるモデルの場所。無ければ nil
    nonisolated static func locate() -> URL? {
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser.path
        let candidates = [
            UserDefaults.standard.string(forKey: preferenceKey),
            ownFolder.appendingPathComponent(modelFile).path,
            "\(home)/.cache/whisper/\(modelFile)",
            "\(home)/.cache/whisper/ggml-large-v3-turbo.bin",
        ].compactMap { $0 }
        return candidates.first(where: { files.fileExists(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    private var task: URLSessionDownloadTask?
    private var session: URLSession?

    /// モデルがあれば ready に、無ければダウンロードを始める。
    func ensure() {
        if let url = Self.locate() {
            state = .ready(url)
            onReady?()
            return
        }
        download()
    }

    /// 動作確認用。手元にモデルがあっても、ダウンロードを行う
    func forceDownloadForTesting() {
        download()
    }

    func retry() {
        if case .downloading = state { return }
        ensure()
    }

    var progressText: String? {
        switch state {
        case .ready: return nil
        case .downloading(let received, let total):
            let percent = total > 0 ? Int(Double(received) / Double(total) * 100) : 0
            return "文字起こしモデルを準備中 \(percent)%（\(Self.gigabytes(received)) / \(total > 0 ? Self.gigabytes(total) : "3.1 GB")）"
        case .failed(let reason):
            return "文字起こしモデルを取得できませんでした（\(reason)）"
        }
    }

    private func download() {
        state = .downloading(received: 0, total: 0)
        let delegate = Delegate(store: self)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        self.session = session
        let task = session.downloadTask(with: Self.downloadURL)
        self.task = task
        task.resume()
    }

    fileprivate func progressed(received: Int64, total: Int64) {
        state = .downloading(received: received, total: total)
    }

    fileprivate func finished(temporary: URL, expectedSize: Int64) {
        let files = FileManager.default
        let destination = folder.appendingPathComponent(Self.modelFile)
        do {
            let size = (try files.attributesOfItem(atPath: temporary.path)[.size] as? Int64) ?? 0
            // 途中で切れたものを本物として扱わない
            guard expectedSize <= 0 || size == expectedSize else {
                throw TsugumiError.message("ダウンロードが途中で終わりました")
            }
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try? files.removeItem(at: destination)
            try files.moveItem(at: temporary, to: destination)
            state = .ready(destination)
            onReady?()
        } catch {
            try? files.removeItem(at: temporary)
            state = .failed(error.localizedDescription)
        }
        cleanup()
    }

    fileprivate func failed(_ error: Error) {
        state = .failed(error.localizedDescription)
        cleanup()
    }

    private func cleanup() {
        session?.finishTasksAndInvalidate()
        session = nil
        task = nil
    }

    nonisolated private static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }

    /// URLSession からの通知を受けて、メインスレッドの ModelStore に渡す。
    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private weak var store: ModelStore?

        init(store: ModelStore) { self.store = store }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let store = store
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    store?.progressed(received: totalBytesWritten, total: totalBytesExpectedToWrite)
                }
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // 一時ファイルはこの関数を抜けると消されるので、先に自分の場所へ動かす
            let kept = FileManager.default.temporaryDirectory.appendingPathComponent("tsugumi-model-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: location, to: kept)
            } catch {
                let store = store
                DispatchQueue.main.async { MainActor.assumeIsolated { store?.failed(error) } }
                return
            }
            let expected = downloadTask.response?.expectedContentLength ?? -1
            let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            let store = store
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard (200..<300).contains(statusCode) else {
                        try? FileManager.default.removeItem(at: kept)
                        store?.failed(TsugumiError.message("サーバーの応答 \(statusCode)"))
                        return
                    }
                    store?.finished(temporary: kept, expectedSize: expected)
                }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error else { return }
            let store = store
            DispatchQueue.main.async { MainActor.assumeIsolated { store?.failed(error) } }
        }
    }
}
