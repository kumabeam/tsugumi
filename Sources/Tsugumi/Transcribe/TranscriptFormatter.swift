import Foundation

/// whisper の結果を、人と AI の両方が読みやすいテキストにまとめる。
enum TranscriptFormatter {
    struct Line {
        var start: Double
        var label: String?
        var text: String
    }

    /// whisper が無音や雑音のところに作ってしまう決まり文句（学習元の動画字幕の名残り）。
    /// 会議でこれを言う人はいないので、含む区間は捨てる
    private static let fillerPhrases = [
        "ご視聴ありがとう", "視聴者によって作成", "ご覧いただきありがとう", "チャンネル登録",
        "Amara.org", "おやすみなさい", "ご清聴ありがとう",
    ]

    /// whisper の決まり文句だけでできた区間か
    static func isFiller(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        guard !compact.isEmpty else { return true }
        // 決まり文句を全部取り除いて、ほとんど何も残らなければ決まり文句だけの区間
        var rest = compact
        for phrase in fillerPhrases {
            rest = rest.replacingOccurrences(of: phrase, with: "")
        }
        return rest.count < 8 && rest.count < compact.count
    }

    /// 同じ文がこの回数以上続いたら、whisper の誤動作（ループ）とみなして1行にまとめる
    private static let repeatLimit = 4
    private static let mergeGap = 1.5
    private static let mergeLength = 140

    static func lines(from segments: [Segment], labelled: Bool) -> [Line] {
        var lines: [Line] = []
        var index = 0
        while index < segments.count {
            let segment = segments[index]
            var runEnd = index + 1
            while runEnd < segments.count, segments[runEnd].text == segment.text { runEnd += 1 }
            let runLength = runEnd - index
            let label = labelled ? speakerLabel(segment.speaker) : nil

            if runLength >= repeatLimit {
                lines.append(Line(start: segment.start, label: label, text: segment.text))
                lines.append(Line(
                    start: segments[index + 1].start, label: nil,
                    text: "（同じ文が\(runLength)回続いたため省略。文字起こしの誤動作の可能性があります）"
                ))
                index = runEnd
                continue
            }

            // 同じ話者の短い発話は1行につなぐ
            if var last = lines.last, last.label == label,
               !last.text.hasPrefix("（同じ文が"),
               segment.start - previousEnd(segments, index) < mergeGap,
               last.text.count + segment.text.count < mergeLength {
                last.text += segment.text
                lines[lines.count - 1] = last
            } else {
                lines.append(Line(start: segment.start, label: label, text: segment.text))
            }
            index += 1
        }
        return lines
    }

    static func markdown(
        lines: [Line], startedAt: Date, duration: Double, sourceNote: String, modelName: String
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "ja_JP")
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        var output = "# 文字起こし \(dateFormatter.string(from: startedAt))\n\n"
        output += "- 長さ: \(durationText(duration))\n"
        output += "- 音源: \(sourceNote)\n"
        output += "- 文字起こし: whisper（\(modelName)）\n"
        output += "- 機械による文字起こしです。数字と固有名詞は音声で確認してください。\n\n---\n\n"
        for line in lines {
            let label = line.label.map { "\($0): " } ?? ""
            output += "[\(timestamp(line.start))] \(label)\(line.text)\n"
        }
        return output
    }

    private static func previousEnd(_ segments: [Segment], _ index: Int) -> Double {
        index > 0 ? segments[index - 1].end : 0
    }

    private static func speakerLabel(_ speaker: String?) -> String {
        switch speaker {
        case "0": return "相手"
        case "1": return "自分"
        default: return "？"
        }
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 { return "\(total / 3600)時間\(total / 60 % 60)分" }
        if total >= 60 { return "\(total / 60)分\(total % 60)秒" }
        return "\(total)秒"
    }
}
