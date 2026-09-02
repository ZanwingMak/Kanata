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
        "aac", "flac", "dts", "dts-hd", "truehd", "ac3", "eac3", "ddp", "opus", "atmos",
        "10bit", "8bit", "hi10p", "ma10p", "dual audio", "dual-audio",
        "60fps", "30fps", "imax", "limited", "series", "korean", "japanese", "repack", "proper",
        "chs", "cht", "gb", "big5", "jptc", "简日双语", "简体", "繁体", "内嵌", "中字", "字幕",
        "tv全集", "全集", "tv版", "剧场版", "合集", "国语", "中配版", "baha", "viutv", "nf",
        "mp4", "mkv", "rmvb", "avi", "mov", "reaction", "超清"
    ]

    /// 解析文件名
    /// - Parameters:
    ///   - fileName: 可带扩展名的文件名。
    ///   - folderNames: 从近到远的父目录名，用于补足 `Season 02/02.mkv` 这类文件。
    /// - Returns: 解析结果，标题为空时表示解析失败
    public static func parse(_ fileName: String, folderNames: [String] = []) -> ParsedTitle {
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
            if result.episode == nil, let episode = matchPlainNumber(core) {
                result.episode = episode
            }
        }

        if result.title.isEmpty {
            result.title = cleanTitle(core.isEmpty ? base : core)
        }
        applyFolderContext(folderNames, into: &result)
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

        // S01E02、S01.E02、S01E02-E03；多集文件以首集参与排序和弹幕匹配。
        if let match = firstMatch(#"(?i)(?<![a-z0-9])s(\d{1,3})\s*[\.\-_ ]?\s*e(\d{1,4})(?:\s*[-_]?\s*(?:e|x)?\d{1,4})*"#, in: working) {
            result.season = Int(match.g1)
            result.episode = Int(match.g2)
            mark(match.start)
            working = removeMatch(#"(?i)(?<![a-z0-9])s\d{1,3}\s*[\.\-_ ]?\s*e\d{1,4}(?:\s*[-_]?\s*(?:e|x)?\d{1,4})*"#, in: working)
        }
        // 中文「第N季 第M集」，同时支持中文数字集号。
        if result.episode == nil,
           let match = firstMatch(#"第\s*([零〇一二两三四五六七八九十百千\d]+)\s*[季期部].{0,8}?第\s*([零〇一二两三四五六七八九十百千\d]+)\s*[集话話回章]"#, in: working) {
            result.season = chineseNumber(match.g1)
            result.episode = chineseNumber(match.g2)
            mark(match.start)
            working = removeMatch(#"第\s*[零〇一二两三四五六七八九十百千\d]+\s*[季期部].{0,8}?第\s*[零〇一二两三四五六七八九十百千\d]+\s*[集话話回章]"#, in: working)
        }
        // 1x02、1x02x03；多集文件同样取首集。
        if result.episode == nil,
           let match = firstMatch(#"(?i)(?<![\d])(\d{1,3})x(\d{1,4})(?:x\d{1,4})*(?![\d])"#, in: working) {
            result.season = Int(match.g1)
            result.episode = Int(match.g2)
            mark(match.start)
            working = removeMatch(#"(?i)(?<![\d])\d{1,3}x\d{1,4}(?:x\d{1,4})*(?![\d])"#, in: working)
        }
        // OVA 02、OAD02、SP03、Special 4 统一视为第 0 季特别篇。
        if result.episode == nil,
           let match = firstMatch(#"(?i)(?<![a-z0-9])(?:ova|oad|sp|special)\s*[._-]?\s*(\d{1,3})(?![a-z0-9])"#, in: working),
           let episode = plausibleEpisode(match.g1) {
            result.season = 0
            result.episode = episode
            mark(match.start)
            working = removeMatch(#"(?i)(?<![a-z0-9])(?:ova|oad|sp|special)\s*[._-]?\s*\d{1,3}(?![a-z0-9])"#, in: working)
        }
        // 单独的季号
        if result.season == nil,
           let match = firstMatch(#"第\s*([零〇一二两三四五六七八九十百千\d]+)\s*[季期部]"#, in: working) {
            result.season = chineseNumber(match.g1)
            mark(match.start)
            working = removeMatch(#"第\s*[零〇一二两三四五六七八九十百千\d]+\s*[季期部]"#, in: working)
        }
        if result.season == nil,
           let match = firstMatch(#"(?i)\bseason\s*(\d{1,2})\b"#, in: working) {
            result.season = Int(match.g1)
            mark(match.start)
            working = removeMatch(#"(?i)\bseason\s*(\d{1,2})\b"#, in: working)
        }
        if result.season == nil,
           let match = firstMatch(#"(?i)(?<![a-z0-9])(\d{1,2})(?:st|nd|rd|th)\s+season\b"#, in: working) {
            result.season = Int(match.g1)
            mark(match.start)
            working = removeMatch(#"(?i)(?<![a-z0-9])\d{1,2}(?:st|nd|rd|th)\s+season\b"#, in: working)
        }
        if result.season == nil,
           let match = firstMatch(#"(?i)\bcour\s*(\d{1,2})\b"#, in: working) {
            result.season = Int(match.g1)
            mark(match.start)
            working = removeMatch(#"(?i)\bcour\s*\d{1,2}\b"#, in: working)
        }
        // 中文集号
        if result.episode == nil,
           let match = firstMatch(#"第\s*([零〇一二两三四五六七八九十百千\d]+)\s*[集话話回章]"#, in: working) {
            result.episode = chineseNumber(match.g1)
            mark(match.start)
            working = removeMatch(#"第\s*[零〇一二两三四五六七八九十百千\d]+\s*[集话話回章]"#, in: working)
        }
        // Episode 02 / EP02 / E02 / #02
        if result.episode == nil,
           let match = firstMatch(#"(?i)(?<![a-z0-9])(?:episode|ep|e|#)\.?\s*(\d{1,4})(?:v\d+)?(?![a-z0-9])"#, in: working),
           let episode = plausibleEpisode(match.g1) {
            result.episode = episode
            mark(match.start)
            working = removeMatch(#"(?i)(?<![a-z0-9])(?:episode|ep|e|#)\.?\s*\d{1,4}(?:v\d+)?(?![a-z0-9])"#, in: working)
        }
        // 分隔符后的动画绝对集号，例如 `孤独摇滚！ - 08v2`。
        if result.episode == nil,
           let match = firstMatch(#"[-–_]\s*(\d{1,4})(?:v\d+)?(?:\s*(?:end|fin))?\s*$"#, in: working),
           let episode = plausibleEpisode(match.g1) {
            result.episode = episode
            mark(match.start)
            working = removeMatch(#"(?i)[-–_]\s*\d{1,4}(?:v\d+)?(?:\s*(?:end|fin))?\s*$"#, in: working)
        }
        // 末尾的裸数字，例如 `名侦探柯南 1082`
        if result.episode == nil,
           let match = firstMatch(#"\s(\d{1,4})(?:v\d+)?(?:\s*(?:END|FIN))?\s*$"#, in: working),
           let episode = plausibleEpisode(match.g1) {
            result.episode = episode
            mark(match.start)
            working = removeMatch(#"(?i)\s\d{1,4}(?:v\d+)?(?:\s*(?:end|fin))?\s*$"#, in: working)
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
            if let episode = matchPlainNumber(block), result.episode == nil {
                result.episode = episode
                continue
            }
            var holder = ParsedTitle(title: "")
            parseCore(block, into: &holder)
            if holder.episode != nil {
                if result.season == nil { result.season = holder.season }
                if result.episode == nil { result.episode = holder.episode }
                continue
            }
            if index == 0 { continue }  // 首块通常是字幕组
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
        if let match = firstMatch(#"^(\d{1,4})(?:v\d+)?(?:\s*(?:END|FIN))?$"#, in: block) {
            return plausibleEpisode(match.g1)
        }
        if let match = firstMatch(#"(?i)^(?:episode|ep|e|#)\.?\s*(\d{1,4})(?:v\d+)?$"#, in: block) {
            return plausibleEpisode(match.g1)
        }
        return nil
    }

    /// 使用父目录补足季度和剧名，但不让 `Season 02` 等结构目录覆盖有效文件标题。
    /// - Parameters:
    ///   - folderNames: 从当前文件父目录开始、由近到远的目录名。
    ///   - result: 已完成文件名解析的结果。
    private static func applyFolderContext(_ folderNames: [String], into result: inout ParsedTitle) {
        if result.season == nil {
            result.season = folderNames.lazy.compactMap(seasonNumber).first
        }
        guard isGenericTitle(result.title) else { return }
        for folder in folderNames {
            let candidate = cleanFolderTitle(folder)
            if !isGenericTitle(candidate), isTitleLike(candidate) {
                result.title = candidate
                return
            }
        }
    }

    /// 从季度目录名称中读取季号，支持 Season/S、中文季度、序数 Season 与 Cour。
    /// - Parameter text: 单层目录名。
    /// - Returns: 识别到的季度；Specials 返回 0。
    private static func seasonNumber(from text: String) -> Int? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if firstMatch(#"(?i)^(?:specials?|特别篇|特別篇)$"#, in: value) != nil { return 0 }
        let patterns = [
            #"(?i)(?:^|[^a-z0-9])season\s*0*(\d{1,3})(?:$|[^a-z0-9])"#,
            #"(?i)^s0*(\d{1,3})$"#,
            #"(?i)(?:^|[^a-z0-9])(\d{1,3})(?:st|nd|rd|th)\s+season(?:$|[^a-z0-9])"#,
            #"(?i)(?:^|[^a-z0-9])cour\s*0*(\d{1,3})(?:$|[^a-z0-9])"#,
        ]
        for pattern in patterns {
            if let match = firstMatch(pattern, in: value), let season = Int(match.g1) { return season }
        }
        if let match = firstMatch(#"第\s*([零〇一二两三四五六七八九十百千\d]+)\s*[季期部]"#, in: value) {
            return chineseNumber(match.g1)
        }
        return nil
    }

    /// 清除父目录中的季度、年份和数据库 ID，只保留可作为剧名的部分。
    /// - Parameter text: 原始目录名。
    /// - Returns: 清理后的候选剧名。
    private static func cleanFolderTitle(_ text: String) -> String {
        var value = text
        value = removeMatch(#"(?i)\{(?:tmdb|tvdb|imdb)(?:id)?[-=][^}]+\}"#, in: value)
        value = removeMatch(#"(?i)\[(?:tmdb|tvdb|imdb)(?:id)?[-=][^\]]+\]"#, in: value)
        value = removeMatch(#"(?i)(?:^|[\s._-])season\s*\d{1,3}(?:$|[\s._-])"#, in: value)
        value = removeMatch(#"(?i)^s\d{1,3}$"#, in: value)
        value = removeMatch(#"第\s*[零〇一二两三四五六七八九十百千\d]+\s*[季期部]"#, in: value)
        value = removeMatch(#"(?i)(?:^|[\s._-])cour\s*\d{1,3}(?:$|[\s._-])"#, in: value)
        value = removeMatch(#"(?i)(?:^|[\s._-])\d{1,3}(?:st|nd|rd|th)\s+season(?:$|[\s._-])"#, in: value)
        return cleanTitle(value)
    }

    /// 判断标题是否只是服务器占位符、集号或季度目录名。
    /// - Parameter text: 已清理的标题。
    /// - Returns: 需要用父目录补全时返回 true。
    private static func isGenericTitle(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.isEmpty || ["file", "video", "stream", "download", "play", "original", "episode", "ep", "e", "未命名视频"].contains(value) {
            return true
        }
        if firstMatch(#"^[\d\s._-]+$"#, in: value) != nil { return true }
        if firstMatch(#"(?i)^(?:s\d{1,3}[._ -]?e\d{1,4}(?:[._ -]?(?:e|x)?\d{1,4})*|\d{1,3}x\d{1,4}(?:x\d{1,4})*|(?:episode|ep|e|#|ova|oad|sp|special)[._ -]?\d{1,4})$"#, in: value) != nil {
            return true
        }
        return seasonNumber(from: value) != nil && cleanFolderTitle(value).isEmpty
    }

    /// 过滤年份、分辨率和画面尺寸等最常被误认为集号的裸数字。
    /// - Parameter text: 正则捕获到的数字。
    /// - Returns: 合理的集号，否则返回 nil。
    private static func plausibleEpisode(_ text: String) -> Int? {
        guard let value = Int(text), value <= 9_999 else { return nil }
        if (1900...2099).contains(value) { return nil }
        let technicalNumbers: Set<Int> = [240, 360, 480, 540, 576, 720, 1080, 1440, 1920, 2160, 3840, 4096, 4320, 7680]
        return technicalNumbers.contains(value) ? nil : value
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

    /// 中文数字转阿拉伯数字，覆盖文件名中常见的零到九千九百九十九。
    /// - Parameter text: 阿拉伯数字或中文数字。
    /// - Returns: 可识别的整数。
    private static func chineseNumber(_ text: String) -> Int? {
        if let value = Int(text) { return value }
        let digits: [Character: Int] = [
            "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
        ]
        let units: [Character: Int] = ["十": 10, "百": 100, "千": 1_000]
        if !text.contains(where: { units[$0] != nil }) {
            let values = text.compactMap { digits[$0] }
            guard values.count == text.count else { return nil }
            return values.reduce(0) { $0 * 10 + $1 }
        }
        var total = 0
        var digit = 0
        for character in text {
            if let value = digits[character] {
                digit = value
            } else if let unit = units[character] {
                total += (digit == 0 ? 1 : digit) * unit
                digit = 0
            } else {
                return nil
            }
        }
        return total + digit
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
