import Foundation
import CoreFoundation

/// 一条带起止时间的外挂字幕。
struct ExternalSubtitleCue: Identifiable, Sendable {
    let id: String
    let start: Double
    let end: Double
    let text: String
}

/// 可由本地目录或网络媒体源读取的一份外挂字幕。
struct ExternalSubtitleResource: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let requestHeaders: [String: String]

    var id: String { url.absoluteString }
}

/// 按视频文件名与设备首选语言筛选、排序外挂字幕。
enum ExternalSubtitlePreference {
    static let supportedExtensions = Set(["srt", "vtt", "ass", "ssa"])

    /// 判断字幕文件是否属于当前视频，允许 `.zh-Hans`、`.chs` 等语言后缀。
    /// - Parameters:
    ///   - subtitleName: 字幕文件名。
    ///   - videoName: 视频文件名。
    /// - Returns: 主文件名相同或字幕名带视频名前缀时返回 true。
    static func matches(subtitleName: String, videoName: String) -> Bool {
        let subtitleStem = URL(fileURLWithPath: subtitleName).deletingPathExtension().lastPathComponent.lowercased()
        let videoStem = URL(fileURLWithPath: videoName).deletingPathExtension().lastPathComponent.lowercased()
        guard !videoStem.isEmpty else { return false }
        return subtitleStem == videoStem
            || subtitleStem.hasPrefix("\(videoStem).")
            || subtitleStem.hasPrefix("\(videoStem)-")
            || subtitleStem.hasPrefix("\(videoStem)_")
    }

    /// 将候选字幕按设备语言、字幕类型和文件名稳定排序。
    /// - Parameters:
    ///   - resources: 待排序字幕。
    ///   - preferredLanguages: 系统语言标识，默认使用设备语言顺序。
    /// - Returns: 最适合本机语言的字幕排在首位。
    static func sorted(
        _ resources: [ExternalSubtitleResource],
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> [ExternalSubtitleResource] {
        resources.sorted { left, right in
            let leftRank = languageRank(fileName: left.name, preferredLanguages: preferredLanguages)
            let rightRank = languageRank(fileName: right.name, preferredLanguages: preferredLanguages)
            if leftRank != rightRank { return leftRank < rightRank }
            let leftFormat = formatRank(left.url.pathExtension)
            let rightFormat = formatRank(right.url.pathExtension)
            if leftFormat != rightFormat { return leftFormat < rightFormat }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    /// 返回字幕语言相对设备语言的优先级，数值越小越优先。
    /// - Parameters:
    ///   - fileName: 字幕文件名、轨道名或语言代码。
    ///   - preferredLanguages: 系统首选语言顺序。
    /// - Returns: 可用于升序排序的语言分值。
    static func languageRank(
        fileName: String,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> Int {
        let normalized = normalizedLanguageText(fileName)
        for (index, language) in preferredLanguages.enumerated() {
            if languageAliases(for: language).contains(where: { containsLanguage($0, in: normalized) }) {
                return index
            }
        }
        let fallbacks = ["zh-hans", "zh-hant", "en"]
        for (index, language) in fallbacks.enumerated() {
            if languageAliases(for: language).contains(where: { containsLanguage($0, in: normalized) }) {
                return preferredLanguages.count + index
            }
        }
        return preferredLanguages.count + fallbacks.count + 1
    }

    /// 返回语言标识常见的文件名别名。
    /// - Parameter identifier: BCP-47 或简写语言标识。
    /// - Returns: 可用于字幕文件名匹配的别名。
    private static func languageAliases(for identifier: String) -> [String] {
        let language = identifier.lowercased().replacingOccurrences(of: "_", with: "-")
        if language.hasPrefix("zh-hans") || language.hasPrefix("zh-cn") || language.hasPrefix("zh-sg") {
            return ["zh-hans", "zh-cn", "zh-sg", "zho", "chi", "chs", "sc", "chinese", "中文", "简体", "简中"]
        }
        if language.hasPrefix("zh-hant") || language.hasPrefix("zh-tw") || language.hasPrefix("zh-hk") {
            return ["zh-hant", "zh-tw", "zh-hk", "zho", "chi", "cht", "tc", "chinese", "中文", "繁体", "繁中"]
        }
        let code = language.split(separator: "-").first.map(String.init) ?? language
        var aliases = [language, code]
        let common: [String: [String]] = [
            "en": ["eng", "english", "英语", "英文"],
            "ja": ["jpn", "japanese", "日语", "日本語"],
            "ko": ["kor", "korean", "韩语", "한국어"],
        ]
        aliases.append(contentsOf: common[code] ?? [])
        if let englishName = Locale(identifier: "en").localizedString(forLanguageCode: code) {
            aliases.append(englishName.lowercased())
        }
        if let localName = Locale.current.localizedString(forLanguageCode: code) {
            aliases.append(localName.lowercased())
        }
        return aliases
    }

    /// 统一文件名分隔符，避免大小写和下划线影响语言识别。
    /// - Parameter value: 原始文件名或语言标签。
    /// - Returns: 小写且使用短横线分隔的文本。
    private static func normalizedLanguageText(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    /// 判断语言别名是否作为独立片段出现在字幕描述中。
    /// - Parameters:
    ///   - alias: 语言别名。
    ///   - value: 已规范化的字幕描述。
    /// - Returns: 命中完整标签或文字别名时返回 true。
    private static func containsLanguage(_ alias: String, in value: String) -> Bool {
        if alias.unicodeScalars.contains(where: { !$0.isASCII }) { return value.contains(alias) }
        let escaped = NSRegularExpression.escapedPattern(for: alias)
        return value.range(of: "(^|[^a-z0-9])\(escaped)([^a-z0-9]|$)", options: .regularExpression) != nil
    }

    /// 返回字幕格式优先级，保留 ASS 样式后依次选择 SRT、VTT 与 SSA。
    /// - Parameter value: 文件扩展名。
    /// - Returns: 可用于升序排序的格式分值。
    private static func formatRank(_ value: String) -> Int {
        switch value.lowercased() {
        case "ass": 0
        case "srt": 1
        case "vtt": 2
        case "ssa": 3
        default: 4
        }
    }
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
    case notFound
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEncoding: "字幕编码无法识别，请转换为 UTF-8、GB18030 或 Big5"
        case .noCues: "没有解析到有效字幕时间轴"
        case .notFound: "当前视频旁没有找到可用的外挂字幕"
        case .http(let statusCode): "外挂字幕下载失败（HTTP \(statusCode)）"
        }
    }
}
