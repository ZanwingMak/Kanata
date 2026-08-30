import Foundation

/// 文件名解析结果（FR-LIB-002）
public struct ParsedTitle: Sendable, Equatable {
    public var title: String
    public var season: Int?
    public var episode: Int?
    public var year: Int?
    public var resolution: String?
    /// 字幕组或发布组
    public var group: String?
    /// 是否为多集合并的合集文件，合集不参与自动集号匹配
    public var isCollection: Bool

    public init(
        title: String,
        season: Int? = nil,
        episode: Int? = nil,
        year: Int? = nil,
        resolution: String? = nil,
        group: String? = nil,
        isCollection: Bool = false
    ) {
        self.title = title
        self.season = season
        self.episode = episode
        self.year = year
        self.resolution = resolution
        self.group = group
        self.isCollection = isCollection
    }
}

/// 从文件名解析剧名、季集号与技术标签。
/// 裸文件源没有元数据，解析质量直接决定弹幕匹配成功率，
/// 解析失败时应由上层降级到目录名或用户手动绑定（docs/04 §4.3）。
public enum TitleParser {

    /// 需要从标题中剥离的技术标签
    private static let technicalTokens: [String] = [
        "2160p", "1080p", "1080i", "720p", "480p", "4k", "8k", "uhd", "hdr10", "hdr", "sdr",
        "web-dl", "webdl", "webrip", "bdrip", "bluray", "blu-ray", "hdtv", "remux", "dvdrip",
        "hevc", "avc", "x264", "x265", "h264", "h265", "h.264", "h.265", "av1", "vc-1",
        "aac", "flac", "dts", "dts-hd", "truehd", "ac3", "eac3", "opus", "10bit", "8bit", "ma10p",
        "60fps", "30fps", "imax", "limited", "series", "korean", "japanese", "repack", "proper",
        "chs", "cht", "gb", "big5", "jptc", "简日双语", "简体", "繁体", "内嵌", "中字", "字幕",
        "tv全集", "全集", "tv版", "剧场版", "合集", "国语", "中配版", "baha", "viutv", "nf",
        "mp4", "mkv", "rmvb", "avi", "mov", "reaction", "超清"
    ]

    /// 解析文件名
    /// - Parameter fileName: 可带扩展名的文件名
    /// - Returns: 解析结果，标题为空时表示解析失败
    public static func parse(_ fileName: String) -> ParsedTitle {
        let base = (fileName as NSString).deletingPathExtension
        let blocks = extractBlocks(from: base)
        let stripped = removeBlocks(from: base)

        var result = ParsedTitle(title: "")
        result.isCollection = detectCollection(base)
        result.group = blocks.first.flatMap { isTitleLike($0) ? nil : $0 }
        result.year = matchYear(base)
        result.resolution = technicalTokens
            .first { ["2160p", "1080p", "720p", "4k", "8k", "480p"].contains($0) && base.lowercased().contains($0) }

        // 主体信息在括号外时优先解析主体，否则退回到括号序列
        let core = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        if isTitleLike(core) {
            parseCore(core, into: &result)
            if result.episode == nil {
                // 标题在括号外、集号在括号内的常见形式，例如 `孤独摇滚！ - 08 [BiliBili]`
                for block in blocks where result.episode == nil {
                    if let episode = matchPlainNumber(block) { result.episode = episode }
                }
            }
        } else {
            parseBlocks(blocks, into: &result)
        }

        if result.title.isEmpty {
            result.title = cleanTitle(core.isEmpty ? base : core)
        }
        if result.episode != nil && result.season == nil {
            result.season = 1
        }
        return result
    }

    // MARK: - 主体解析

    /// 从括号外的主体文本中提取季集号与标题
    private static func parseCore(_ core: String, into result: inout ParsedTitle) {
        var working = core
        // 最早一个季集号匹配的起点，标题截断到这里
        var titleCut: Int?
        func mark(_ start: Int) { titleCut = min(titleCut ?? start, start) }

        // S01E02 / s01 e02
        if let match = firstMatch(#"[Ss](\d{1,2})\s*[\.\-_ ]?\s*[Ee](\d{1,4})"#, in: working) {
            result.season = Int(match.g1)
            result.episode = Int(match.g2)
            mark(match.start)
            working = removeMatch(#"[Ss](\d{1,2})\s*[\.\-_ ]?\s*[Ee](\d{1,4})"#, in: working)
        }
        // 中文「第N季 第M集」
        if result.episode == nil,
           let match = firstMatch(#"第\s*([一二三四五六七八九十\d]+)\s*[季期部].{0,4}?第\s*(\d{1,4})\s*[集话話回]"#, in: working) {
            result.season = chineseNumber(match.g1)
            result.episode = Int(match.g2)
            mark(match.start)
            working = removeMatch(#"第\s*([一二三四五六七八九十\d]+)\s*[季期部].{0,4}?第\s*(\d{1,4})\s*[集话話回]"#, in: working)
        }
        // 1x02
        if result.episode == nil,
           let match = firstMatch(#"(?<![\d])(\d{1,2})[xX](\d{1,4})(?![\d])"#, in: working) {
            result.season = Int(match.g1)
            result.episode = Int(match.g2)
            mark(match.start)
            working = removeMatch(#"(?<![\d])(\d{1,2})[xX](\d{1,4})(?![\d])"#, in: working)
        }
        // 单独的季号
        if result.season == nil,
           let match = firstMatch(#"第\s*([一二三四五六七八九十\d]+)\s*[季期部]"#, in: working) {
            result.season = chineseNumber(match.g1)
            mark(match.start)
            working = removeMatch(#"第\s*([一二三四五六七八九十\d]+)\s*[季期部]"#, in: working)
        }
        if result.season == nil,
           let match = firstMatch(#"(?i)\bseason\s*(\d{1,2})\b"#, in: working) {
            result.season = Int(match.g1)
            mark(match.start)
            working = removeMatch(#"(?i)\bseason\s*(\d{1,2})\b"#, in: working)
        }
        // 中文集号
        if result.episode == nil,
           let match = firstMatch(#"第\s*(\d{1,4})\s*[集话話回]"#, in: working) {
            result.episode = Int(match.g1)
            mark(match.start)
            working = removeMatch(#"第\s*(\d{1,4})\s*[集话話回]"#, in: working)
        }
        // EP02 / E02
        if result.episode == nil,
           let match = firstMatch(#"(?i)(?<![a-z0-9])ep?\.?\s*(\d{1,4})(?![a-z0-9])"#, in: working) {
            result.episode = Int(match.g1)
            mark(match.start)
            working = removeMatch(#"(?i)(?<![a-z0-9])ep?\.?\s*(\d{1,4})(?![a-z0-9])"#, in: working)
        }
        // 分隔符后的裸数字，例如 `孤独摇滚！ - 08`、`庆余年第二季-06`
        if result.episode == nil,
           let match = firstMatch(#"[-–_]\s*(\d{1,4})\s*$"#, in: working) {
            result.episode = Int(match.g1)
            mark(match.start)
            working = removeMatch(#"[-–_]\s*(\d{1,4})\s*$"#, in: working)
        }
        // 末尾的裸数字，例如 `名侦探柯南 1082`
        if result.episode == nil,
           let match = firstMatch(#"\s(\d{2,4})\s*$"#, in: working) {
            result.episode = Int(match.g1)
            mark(match.start)
            working = removeMatch(#"\s(\d{2,4})\s*$"#, in: working)
        }

        // 标题取最早一个季集号匹配之前的部分；没有集号时用整段主体
        if let cut = titleCut, let index = String.Index(utf16Offset: cut, in: core) as String.Index?, cut <= core.utf16.count {
            result.title = cleanTitle(String(core[core.startIndex..<index]))
        } else {
            result.title = cleanTitle(working)
        }
    }

    /// 主体信息也在括号内时，按块推断标题与集号
    private static func parseBlocks(_ blocks: [String], into result: inout ParsedTitle) {
        var titleCandidates: [String] = []
        for (index, block) in blocks.enumerated() {
            if index == 0 { continue }  // 首块通常是字幕组
            if let episode = matchPlainNumber(block), result.episode == nil {
                result.episode = episode
                continue
            }
            if isTitleLike(block) { titleCandidates.append(block) }
        }
        // 标题取第一个像标题的块——字幕组之后紧跟的通常就是作品名
        if let best = titleCandidates.first {
            var holder = ParsedTitle(title: "")
            parseCore(best, into: &holder)
            result.title = holder.title
            if result.season == nil { result.season = holder.season }
            if result.episode == nil { result.episode = holder.episode }
        }
        // 季号可能单独成块，例如 [S2]
        for block in blocks {
            if result.season == nil, let match = firstMatch(#"(?i)^s(\d{1,2})$"#, in: block) {
                result.season = Int(match.g1)
            }
        }
    }

    // MARK: - 工具

    /// 提取所有括号块的内容
    private static func extractBlocks(from text: String) -> [String] {
        let pattern = #"[\[【(（]([^\[\]【】()（）]+)[\]】)）]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r]).trimmingCharacters(in: .whitespaces)
        }
    }

    /// 移除所有括号块
    private static func removeBlocks(from text: String) -> String {
        removeMatch(#"[\[【(（][^\[\]【】()（）]*[\]】)）]"#, in: text)
    }

    /// 判断一段文本是否像标题：含有中日韩文字或多个字母单词，且不是纯技术标签
    private static func isTitleLike(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return false }
        let lower = trimmed.lowercased()
        if technicalTokens.contains(where: { lower == $0 }) { return false }
        if firstMatch(#"^[\d\s\-_.]+$"#, in: trimmed) != nil { return false }
        if firstMatch(#"^\d{3,4}[xX×]\d{3,4}$"#, in: trimmed) != nil { return false }
        // `01-15TV全集` 这类合集标记不是标题
        if firstMatch(#"^\d{1,3}\s*[-~]\s*\d{1,3}"#, in: trimmed) != nil { return false }
        // 去掉技术标签后仍有实义内容才算标题
        let stripped = cleanTitle(trimmed)
        return stripped.count >= 2
    }

    /// 括号内的纯数字集号，例如 [01]、[EP03]
    private static func matchPlainNumber(_ block: String) -> Int? {
        if let match = firstMatch(#"^(\d{1,4})$"#, in: block) {
            guard let value = Int(match.g1) else { return nil }
            // 1900-2099 视为年份而非集号
            return (1900...2099).contains(value) ? nil : value
        }
        if let match = firstMatch(#"(?i)^ep?\.?\s*(\d{1,4})$"#, in: block) { return Int(match.g1) }
        return nil
    }

    /// 识别合集文件，例如 [01-15TV全集]
    private static func detectCollection(_ text: String) -> Bool {
        firstMatch(#"(?<![\d])\d{1,3}\s*[-~]\s*\d{1,3}(?![\d])"#, in: text) != nil
            && (text.contains("全集") || text.contains("合集") || firstMatch(#"(?i)\bcomplete\b"#, in: text) != nil)
    }

    /// 提取 1900-2099 之间的年份
    private static func matchYear(_ text: String) -> Int? {
        guard let match = firstMatch(#"(?<![\d])((?:19|20)\d{2})(?![\d])"#, in: text) else { return nil }
        return Int(match.g1)
    }

    /// 清理标题：去技术标签、去年份、去多余分隔符
    private static func cleanTitle(_ text: String) -> String {
        var working = text
        working = removeMatch(#"(?<![\d])(?:19|20)\d{2}(?![\d])"#, in: working)
        for token in technicalTokens {
            working = working.replacingOccurrences(
                of: "(?<![a-zA-Z0-9])\(NSRegularExpression.escapedPattern(for: token))(?![a-zA-Z0-9])",
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        working = working.replacingOccurrences(of: #"[._]+"#, with: " ", options: .regularExpression)
        working = working.replacingOccurrences(of: #"\s*[-–]\s*$"#, with: "", options: .regularExpression)
        working = working.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        // 去掉 `-RARBG` 这类挂在末尾的发布组
        working = working.replacingOccurrences(
            of: #"\s*[-–]\s*[A-Za-z][A-Za-z0-9]{1,9}\s*$"#,
            with: "",
            options: .regularExpression
        )
        working = working.trimmingCharacters(in: CharacterSet(charactersIn: " -–_.:：、~"))
        return preferChineseSegment(working)
    }

    /// 中英双语标题优先保留中文部分，例如 `三体 Three-Body` → `三体`。
    /// 仅在首个词含中日韩文字时生效，避免误伤 `Fate/Zero 命运之夜` 这类英文开头的标题。
    private static func preferChineseSegment(_ text: String) -> String {
        let words = text.split(separator: " ").map(String.init)
        guard let first = words.first, containsCJK(first), words.count > 1 else { return text }
        var kept: [String] = []
        for word in words {
            guard containsCJK(word) else { break }
            kept.append(word)
        }
        return kept.isEmpty ? text : kept.joined(separator: " ")
    }

    /// 判断字符串是否含中日韩表意文字
    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0x3040...0x30FF).contains(scalar.value)
        }
    }

    /// 中文数字转阿拉伯数字，仅覆盖 1-20 的常见写法
    private static func chineseNumber(_ text: String) -> Int? {
        if let value = Int(text) { return value }
        let digits = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
                      "六": 6, "七": 7, "八": 8, "九": 9, "十": 10]
        if let single = digits[text] { return single }
        if text.hasPrefix("十"), text.count == 2 {
            let tail = String(text.suffix(1))
            return 10 + (digits[tail] ?? 0)
        }
        if text.hasSuffix("十"), text.count == 2 {
            let head = String(text.prefix(1))
            return (digits[head] ?? 0) * 10
        }
        return nil
    }

    /// 返回首个匹配的前两个捕获组与匹配起点。
    /// 起点用于把标题截断到季集号之前——集号后面通常是单集标题或发布组信息。
    private static func firstMatch(
        _ pattern: String,
        in text: String
    ) -> (g1: String, g2: String, start: Int)? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        func group(_ index: Int) -> String {
            guard index < match.numberOfRanges,
                  let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
        return (group(1), group(2), match.range.location)
    }

    /// 删除所有匹配片段
    private static func removeMatch(_ pattern: String, in text: String) -> String {
        text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
    }
}
