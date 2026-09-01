import Foundation
import CoreFoundation

/// 一条带起止时间的外挂字幕。
struct ExternalSubtitleCue: Identifiable, Sendable {
    let id: String
    let start: Double
    let end: Double
    let text: String
}

/// SRT、WebVTT 与基础 ASS/SSA 字幕解析器。
enum ExternalSubtitleParser {
    /// 根据扩展名解析外挂字幕，并兼容常见中文编码。
    /// - Parameters:
    ///   - data: 字幕文件内容。
    ///   - fileName: 用于判断格式的文件名。
    /// - Returns: 按开始时间排序的字幕列表。
    static func parse(data: Data, fileName: String) throws -> [ExternalSubtitleCue] {
        guard let text = decode(data) else { throw ExternalSubtitleError.invalidEncoding }
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        let cues = ["ass", "ssa"].contains(ext) ? parseASS(text) : parseTimedText(text)
        guard !cues.isEmpty else { throw ExternalSubtitleError.noCues }
        return cues.sorted { $0.start < $1.start }
    }

    /// 用 UTF-8、GB18030 与 Big5 顺序解码文本。
    /// - Parameter data: 原始文件数据。
    /// - Returns: 成功解码的字符串。
    private static func decode(_ data: Data) -> String? {
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.big5.rawValue)
        ))
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: gb18030)
            ?? String(data: data, encoding: big5)
    }

    /// 解析 SRT 与 WebVTT 的时间箭头块。
    /// - Parameter text: 已解码字幕文本。
    /// - Returns: 有效字幕条目。
    private static func parseTimedText(_ text: String) -> [ExternalSubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        return blocks.enumerated().compactMap { offset, block in
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let sides = lines[timeIndex].components(separatedBy: "-->")
            guard sides.count == 2,
                  let start = parseTime(sides[0]),
                  let end = parseTime(sides[1]) else { return nil }
            let value = lines.dropFirst(timeIndex + 1)
                .joined(separator: "\n")
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, end > start else { return nil }
            return ExternalSubtitleCue(id: "text-\(offset)-\(start)", start: start, end: end, text: value)
        }
    }

    /// 解析 ASS/SSA Dialogue 行并去除样式控制标签。
    /// - Parameter text: ASS 或 SSA 文本。
    /// - Returns: 转成普通双行字幕的条目。
    private static func parseASS(_ text: String) -> [ExternalSubtitleCue] {
        text.components(separatedBy: .newlines).enumerated().compactMap { offset, line in
            guard line.lowercased().hasPrefix("dialogue:") else { return nil }
            let payload = String(line.dropFirst(line.firstIndex(of: ":").map { line.distance(from: line.startIndex, to: $0) + 1 } ?? 0))
            let fields = payload.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 10,
                  let start = parseTime(fields[1]),
                  let end = parseTime(fields[2]),
                  end > start else { return nil }
            let value = fields[9]
                .replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            return ExternalSubtitleCue(id: "ass-\(offset)-\(start)", start: start, end: end, text: value)
        }
    }

    /// 解析 h:mm:ss.mmm、mm:ss,mmm 或 ASS 百分秒时间。
    /// - Parameter raw: 时间字段，允许箭头后的样式参数。
    /// - Returns: 秒数。
    private static func parseTime(_ raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 1)
            .first
            .map(String.init)?
            .replacingOccurrences(of: ",", with: ".") ?? ""
        let parts = value.split(separator: ":").compactMap { Double($0) }
        guard parts.count >= 2 else { return nil }
        if parts.count == 3 { return parts[0] * 3_600 + parts[1] * 60 + parts[2] }
        return parts[0] * 60 + parts[1]
    }
}

/// 外挂字幕导入错误。
enum ExternalSubtitleError: LocalizedError {
    case invalidEncoding
    case noCues

    var errorDescription: String? {
        switch self {
        case .invalidEncoding: "字幕编码无法识别，请转换为 UTF-8、GB18030 或 Big5"
        case .noCues: "没有解析到有效字幕时间轴"
        }
    }
}
