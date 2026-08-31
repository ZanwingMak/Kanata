import Foundation

/// 一类弹幕文件占用的空间统计。
public struct DanmakuStorageUsage: Sendable {
    public let fileCount: Int
    public let totalBytes: Int64

    /// 创建不可变的空间统计结果。
    public init(fileCount: Int, totalBytes: Int64) {
        self.fileCount = fileCount
        self.totalBytes = totalBytes
    }
}

/// 一次在线弹幕响应的设备端离线归档。
public struct CachedDanmakuArchive: Codable, Sendable {
    public let candidate: ProviderCandidate
    public let items: [DanmakuItem]
    public let cachedAt: Date
    public var lastAccessedAt: Date

    /// 创建在线弹幕缓存归档。
    public init(
        candidate: ProviderCandidate,
        items: [DanmakuItem],
        cachedAt: Date = Date(),
        lastAccessedAt: Date = Date()
    ) {
        self.candidate = candidate
        self.items = items
        self.cachedAt = cachedAt
        self.lastAccessedAt = lastAccessedAt
    }
}

/// 按视频指纹持久化在线弹幕，在网关或网络不可用时提供设备端兜底。
public actor DanmakuCacheStore {
    public static let shared = DanmakuCacheStore()

    private let directoryURL: URL
    private let fileManager: FileManager

    /// 创建在线弹幕缓存存储，默认使用系统 Caches 目录。
    private init() {
        let fileManager = FileManager.default
        self.fileManager = fileManager
        let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        directoryURL = root.appendingPathComponent("Kanata/OnlineDanmaku", isDirectory: true)
    }

    /// 读取当前视频与候选相符的缓存，并更新最近访问时间。
    public func load(
        for fingerprint: MediaFingerprint,
        candidate: ProviderCandidate
    ) throws -> CachedDanmakuArchive? {
        let url = archiveURL(for: fingerprint)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            var archive = try JSONDecoder().decode(CachedDanmakuArchive.self, from: Data(contentsOf: url))
            guard archive.candidate.source == candidate.source,
                  archive.candidate.platformEpisodeId == candidate.platformEpisodeId else {
                return nil
            }
            archive.lastAccessedAt = Date()
            try JSONEncoder().encode(archive).write(to: url, options: .atomic)
            return archive
        } catch {
            try? fileManager.removeItem(at: url)
            return nil
        }
    }

    /// 保存在线弹幕并按用户配置的空间上限执行 LRU 裁剪。
    public func save(
        items: [DanmakuItem],
        candidate: ProviderCandidate,
        for fingerprint: MediaFingerprint,
        maximumBytes: Int64
    ) throws {
        guard !items.isEmpty else { return }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let archive = CachedDanmakuArchive(candidate: candidate, items: items)
        let data = try JSONEncoder().encode(archive)
        try data.write(to: archiveURL(for: fingerprint), options: .atomic)
        try trim(to: maximumBytes)
    }

    /// 返回全部在线弹幕缓存的文件数量与字节数。
    public func usage() -> DanmakuStorageUsage {
        usage(of: archiveFiles())
    }

    /// 删除全部在线弹幕缓存。
    public func removeAll() throws {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        try fileManager.removeItem(at: directoryURL)
    }

    /// 按最近修改时间删除最旧缓存，直到占用不超过上限。
    public func trim(to maximumBytes: Int64) throws {
        guard maximumBytes > 0 else {
            try removeAll()
            return
        }
        let files = archiveFiles().sorted {
            modificationDate(of: $0) < modificationDate(of: $1)
        }
        var totalBytes = usage(of: files).totalBytes
        for file in files where totalBytes > maximumBytes {
            let bytes = fileSize(of: file)
            try fileManager.removeItem(at: file)
            totalBytes -= bytes
        }
    }

    /// 返回在线弹幕目录中的 JSON 归档文件。
    private func archiveFiles() -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension.lowercased() == "json" } ?? []
    }

    /// 汇总文件列表的数量和大小。
    private func usage(of files: [URL]) -> DanmakuStorageUsage {
        DanmakuStorageUsage(
            fileCount: files.count,
            totalBytes: files.reduce(0) { $0 + fileSize(of: $1) }
        )
    }

    /// 读取单个缓存文件大小，读取失败时按零处理。
    private func fileSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    /// 读取缓存文件修改时间，缺失时视为最旧文件。
    private func modificationDate(of url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
    }

    /// 生成只包含视频哈希与大小的安全缓存路径。
    private func archiveURL(for fingerprint: MediaFingerprint) -> URL {
        directoryURL.appendingPathComponent("\(fingerprint.fileHash)-\(fingerprint.fileSize).json")
    }
}
