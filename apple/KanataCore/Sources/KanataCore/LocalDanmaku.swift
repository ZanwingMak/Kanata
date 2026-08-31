import Foundation

/// 本地弹幕解析或存储时可向界面展示的错误。
public enum LocalDanmakuError: Error, LocalizedError, Sendable {
    case unsupportedFormat(String)
    case invalidData(String)
    case noDanmaku

    /// 返回适合直接展示给用户的错误说明。
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let fileExtension):
            return "暂不支持 .\(fileExtension) 弹幕文件"
        case .invalidData(let reason):
            return "弹幕文件格式错误：\(reason)"
        case .noDanmaku:
            return "文件中没有可导入的弹幕"
        }
    }
}

/// 已导入并持久化的本地弹幕归档。
public struct LocalDanmakuArchive: Codable, Sendable {
    public let fileName: String
    public let importedAt: Date
    public let items: [DanmakuItem]

    /// 创建一份可持久化的本地弹幕归档。
    public init(fileName: String, importedAt: Date = Date(), items: [DanmakuItem]) {
        self.fileName = fileName
        self.importedAt = importedAt
        self.items = items
    }
}

/// 解析 bilibili XML、dandanplay/DPlayer JSON 与 ASS 弹幕文件。
public enum LocalDanmakuParser {
    /// 按扩展名解析弹幕文件，并统一转换为 Kanata 弹幕模型。
    public static func parse(data: Data, fileName: String) throws -> [DanmakuItem] {
        let fileExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        let items: [DanmakuItem]
        switch fileExtension {
        case "xml":
            items = try parseBilibiliXML(data)
        case "json":
            items = try parseJSON(data)
        case "ass":
            items = try parseASS(data)
        default:
            throw LocalDanmakuError.unsupportedFormat(fileExtension.isEmpty ? "未知格式" : fileExtension)
        }
        guard !items.isEmpty else { throw LocalDanmakuError.noDanmaku }
        return items.sorted { $0.time < $1.time }
    }

    /// 解析 bilibili XML 的 d 节点与 p 属性。
    private static func parseBilibiliXML(_ data: Data) throws -> [DanmakuItem] {
        let delegate = BilibiliXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw LocalDanmakuError.invalidData(parser.parserError?.localizedDescription ?? "XML 无法解析")
        }
        return delegate.items
    }

    /// 识别并解析 dandanplay 或 DPlayer JSON。
    private static func parseJSON(_ data: Data) throws -> [DanmakuItem] {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LocalDanmakuError.invalidData(error.localizedDescription)
        }

        if let object = root as? [String: Any], let comments = object["comments"] as? [[String: Any]] {
            return parseDandanplayComments(comments)
        }
        if let object = root as? [String: Any], let rows = object["data"] as? [[Any]] {
            return parseDPlayerRows(rows)
        }
        if let rows = root as? [[Any]] {
            return parseDPlayerRows(rows)
        }
        throw LocalDanmakuError.invalidData("无法识别 JSON 弹幕结构")
    }

    /// 将 dandanplay comments 数组转换为统一弹幕。
    private static func parseDandanplayComments(_ comments: [[String: Any]]) -> [DanmakuItem] {
        comments.enumerated().compactMap { index, comment in
            guard let content = comment["m"] as? String, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let parameters = comment["p"] as? String else { return nil }
            let parts = parameters.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, let time = Double(parts[0]), time >= 0 else { return nil }
            let mode = danmakuMode(from: Int(parts[1]) ?? 1)
            let color = normalizedColor(parts[2])
            let sender = parts.count > 3 && !parts[3].isEmpty ? parts[3] : nil
            let identifier = stringValue(comment["cid"]) ?? "\(index)"
            return localItem(
                id: "local:dandanplay:\(identifier)", time: time, mode: mode,
                color: color, content: content, senderHash: sender
            )
        }
    }

    /// 将 DPlayer data 数组转换为统一弹幕。
    private static func parseDPlayerRows(_ rows: [[Any]]) -> [DanmakuItem] {
        rows.enumerated().compactMap { index, row in
            guard row.count >= 5,
                  let time = doubleValue(row[0]), time >= 0,
                  let content = row[4] as? String,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let dplayerMode = intValue(row[1]) ?? 0
            let mode: DanmakuMode = switch dplayerMode {
            case 1: .top
            case 2: .bottom
            default: .scroll
            }
            return localItem(
                id: "local:dplayer:\(index)", time: time, mode: mode,
                color: normalizedColor(row[2]), content: content,
                senderHash: stringValue(row[3])
            )
        }
    }

    /// 解析 ASS Events 区域中的 Dialogue 行。
    private static func parseASS(_ data: Data) throws -> [DanmakuItem] {
        guard let content = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .unicode)
                ?? String(data: data, encoding: .windowsCP1252) else {
            throw LocalDanmakuError.invalidData("无法识别文本编码")
        }

        var isInEvents = false
        var format = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var items: [DanmakuItem] = []

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") {
                isInEvents = line.caseInsensitiveCompare("[Events]") == .orderedSame
                continue
            }
            guard isInEvents else { continue }
            if line.lowercased().hasPrefix("format:") {
                format = line.dropFirst("format:".count)
                    .split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                continue
            }
            guard line.lowercased().hasPrefix("dialogue:"),
                  let startIndex = format.firstIndex(of: "start"),
                  let textIndex = format.firstIndex(of: "text") else { continue }
            let fields = line.dropFirst("dialogue:".count)
                .split(separator: ",", maxSplits: max(format.count - 1, 0), omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.indices.contains(startIndex), fields.indices.contains(textIndex),
                  let time = assTime(fields[startIndex]) else { continue }
            let text = cleanASSText(fields[textIndex])
            guard !text.isEmpty else { continue }
            items.append(localItem(id: "local:ass:\(items.count)", time: time, mode: .scroll, content: text))
        }
        return items
    }

    /// 将常见平台模式编号映射为统一模式。
    private static func danmakuMode(from value: Int) -> DanmakuMode {
        switch value {
        case 4: .bottom
        case 5: .top
        case 6: .reverse
        default: .scroll
        }
    }

    /// 将任意数字表示转换为 Double。
    private static func doubleValue(_ value: Any) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    /// 将任意数字表示转换为 Int。
    private static func intValue(_ value: Any) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    /// 将 JSON 标识转换为字符串。
    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// 解析十进制、十六进制或 #RRGGBB 颜色并限制在 RGB 范围。
    private static func normalizedColor(_ value: Any) -> Int {
        if let number = value as? NSNumber {
            return min(max(number.intValue, 0), 0xFF_FF_FF)
        }
        guard var string = value as? String else { return 0xFF_FF_FF }
        string = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed: Int?
        if string.hasPrefix("#") {
            parsed = Int(string.dropFirst(), radix: 16)
        } else if string.lowercased().hasPrefix("0x") {
            parsed = Int(string.dropFirst(2), radix: 16)
        } else {
            parsed = Int(string)
        }
        return min(max(parsed ?? 0xFF_FF_FF, 0), 0xFF_FF_FF)
    }

    /// 解析 ASS 的 h:mm:ss.cc 时间格式。
    private static func assTime(_ value: String) -> Double? {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    /// 移除 ASS 样式标签并把显式换行转换为空格。
    private static func cleanASSText(_ value: String) -> String {
        value.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\N", with: " ")
            .replacingOccurrences(of: "\\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 创建统一的本地弹幕条目。
    private static func localItem(
        id: String,
        time: Double,
        mode: DanmakuMode,
        fontSize: Double = 25,
        color: Int = 0xFF_FF_FF,
        content: String,
        senderHash: String? = nil,
        createdAt: Int? = nil
    ) -> DanmakuItem {
        DanmakuItem(
            id: id, time: time, mode: mode, fontSize: fontSize, color: color,
            content: content, source: .local, senderHash: senderHash, createdAt: createdAt
        )
    }
}

/// 负责收集 bilibili XML 中可能被拆分回调的文本节点。
private final class BilibiliXMLDelegate: NSObject, XMLParserDelegate {
    private(set) var items: [DanmakuItem] = []
    private var parameters: [String]?
    private var text = ""

    /// 进入 d 节点时保存 p 属性并开始收集正文。
    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "d", let parameter = attributeDict["p"] else { return }
        parameters = parameter.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        text = ""
    }

    /// 累加 XMLParser 分批返回的正文。
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard parameters != nil else { return }
        text += string
    }

    /// 离开 d 节点时创建统一弹幕条目。
    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard elementName == "d", let parts = parameters else { return }
        defer {
            parameters = nil
            text = ""
        }
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard parts.count >= 4, let time = Double(parts[0]), time >= 0, !content.isEmpty else { return }
        let identifier = parts.count > 7 && !parts[7].isEmpty ? parts[7] : "\(items.count)"
        let sender = parts.count > 6 && !parts[6].isEmpty ? parts[6] : nil
        let createdAt = parts.count > 4 ? Int(parts[4]) : nil
        items.append(
            DanmakuItem(
                id: "local:bilibili:\(identifier)",
                time: time,
                mode: Self.mode(from: Int(parts[1]) ?? 1),
                fontSize: Double(parts[2]) ?? 25,
                color: min(max(Int(parts[3]) ?? 0xFF_FF_FF, 0), 0xFF_FF_FF),
                content: content,
                source: .local,
                senderHash: sender,
                createdAt: createdAt
            )
        )
    }

    /// 将 bilibili 模式编号映射为统一模式，忽略高级模式差异。
    private static func mode(from value: Int) -> DanmakuMode {
        switch value {
        case 4: .bottom
        case 5: .top
        case 6: .reverse
        default: .scroll
        }
    }
}

/// 按视频内容指纹把用户导入的弹幕持久化到 Application Support。
public actor LocalDanmakuStore {
    public static let shared = LocalDanmakuStore()

    private let directoryURL: URL
    private let fileManager: FileManager

    /// 创建本地弹幕存储，默认写入应用支持目录。
    private init() {
        let fileManager = FileManager.default
        self.fileManager = fileManager
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        directoryURL = root.appendingPathComponent("Kanata/LocalDanmaku", isDirectory: true)
    }

    /// 读取指定视频已导入的本地弹幕；不存在时返回 nil。
    public func load(for fingerprint: MediaFingerprint) throws -> LocalDanmakuArchive? {
        let url = archiveURL(for: fingerprint)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(LocalDanmakuArchive.self, from: Data(contentsOf: url))
        } catch {
            throw LocalDanmakuError.invalidData("本地弹幕缓存损坏：\(error.localizedDescription)")
        }
    }

    /// 保存或替换指定视频关联的本地弹幕。
    public func save(items: [DanmakuItem], fileName: String, for fingerprint: MediaFingerprint) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let archive = LocalDanmakuArchive(fileName: fileName, items: items)
        do {
            let data = try JSONEncoder().encode(archive)
            try data.write(to: archiveURL(for: fingerprint), options: .atomic)
        } catch {
            throw LocalDanmakuError.invalidData("无法保存本地弹幕：\(error.localizedDescription)")
        }
    }

    /// 删除指定视频关联的本地弹幕归档。
    public func remove(for fingerprint: MediaFingerprint) throws {
        let url = archiveURL(for: fingerprint)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    /// 返回全部用户导入弹幕的文件数量与字节数。
    public func usage() -> DanmakuStorageUsage {
        let files = archiveFiles()
        let bytes = files.reduce(Int64(0)) { result, url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            return result + Int64(values?.fileSize ?? 0)
        }
        return DanmakuStorageUsage(fileCount: files.count, totalBytes: bytes)
    }

    /// 删除全部用户导入的本地弹幕归档。
    public func removeAll() throws {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        try fileManager.removeItem(at: directoryURL)
    }

    /// 返回本地弹幕目录中的 JSON 归档文件。
    private func archiveFiles() -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension.lowercased() == "json" } ?? []
    }

    /// 生成仅由十六进制指纹与文件大小构成的归档路径。
    private func archiveURL(for fingerprint: MediaFingerprint) -> URL {
        directoryURL.appendingPathComponent("\(fingerprint.fileHash)-\(fingerprint.fileSize).json")
    }
}
