import Foundation

/// 文字起こしの1行。
struct TranscriptLine: Identifiable, Equatable {
    let id: Int
    /// 発言が始まる時刻（秒）
    let start: Double
    /// 「相手」「自分」など。付いていない文字起こしもある
    let label: String?
    let text: String
}

/// transcript.md を読んで、画面に出せる行の並びに戻す。
enum TranscriptDocument {
    private static let labels = ["相手", "自分", "？"]

    static func load(_ url: URL) -> [TranscriptLine] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var lines: [TranscriptLine] = []

        // 本文は "[00:01:23] 相手: こんにちは" の形。それ以外（見出しなど）は読み飛ばす
        for raw in content.split(separator: "\n") {
            guard raw.hasPrefix("["), let close = raw.firstIndex(of: "]") else { continue }
            let parts = raw[raw.index(after: raw.startIndex)..<close].split(separator: ":").compactMap { Double($0) }
            guard parts.count == 3 else { continue }

            var rest = raw[raw.index(after: close)...].drop { $0 == " " }
            var label: String?
            for candidate in labels where rest.hasPrefix(candidate + ": ") {
                label = candidate
                rest = rest.dropFirst(candidate.count + 2)
            }
            lines.append(TranscriptLine(
                id: lines.count,
                start: parts[0] * 3600 + parts[1] * 60 + parts[2],
                label: label,
                text: String(rest)
            ))
        }
        return lines
    }
}
