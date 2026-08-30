import CryptoKit
import Foundation

/// 可按字节区间读取的媒体源。
/// 本地文件直接 seek，网络源用 HTTP Range 请求实现（docs/04 §2.3）。
public protocol ByteRangeReadable: Sendable {
    /// 读取指定区间的字节
    /// - Parameters:
    ///   - offset: 起始偏移
    ///   - length: 期望长度，实际返回可能更短
    /// - Returns: 读到的字节，文件不足时返回实际长度
    func readRange(offset: Int, length: Int) async throws -> Data

    /// 文件总大小（字节）
    func fileSize() async throws -> Int
}

public enum FingerprintError: Error, Sendable {
    case fileNotReadable(String)
    case emptyFile
}

/// 文件识别指纹计算（FR-MATCH-001）。
/// 弹弹play 规范：取文件**前 16MB** 的 MD5，文件不足 16MB 时取全部内容。
public enum FingerprintCalculator {
    /// 参与哈希的字节数上限
    public static let hashByteCount = 16 * 1024 * 1024

    /// 计算本地文件的识别指纹
    /// - Parameters:
    ///   - fileURL: 本地文件地址
    ///   - duration: 视频时长（秒），由播放内核探测得到
    /// - Returns: 可直接提交给网关 /api/v2/match 的指纹
    /// - Throws: 文件无法读取或为空时抛出 FingerprintError
    public static func compute(fileURL: URL, duration: Double) throws -> MediaFingerprint {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            throw FingerprintError.fileNotReadable(fileURL.lastPathComponent)
        }
        defer { try? handle.close() }

        let data = try handle.read(upToCount: hashByteCount) ?? Data()
        guard !data.isEmpty else { throw FingerprintError.emptyFile }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? data.count

        return MediaFingerprint(
            fileName: fileURL.deletingPathExtension().lastPathComponent,
            fileHash: md5Hex(data),
            fileSize: fileSize,
            videoDuration: Int(duration.rounded())
        )
    }

    /// 计算任意可按区间读取的媒体源的识别指纹
    /// - Parameters:
    ///   - reader: 支持 Range 读取的源
    ///   - fileName: 不含扩展名的文件名
    ///   - duration: 视频时长（秒）
    public static func compute(
        reader: any ByteRangeReadable,
        fileName: String,
        duration: Double
    ) async throws -> MediaFingerprint {
        let data = try await reader.readRange(offset: 0, length: hashByteCount)
        guard !data.isEmpty else { throw FingerprintError.emptyFile }
        let size = try await reader.fileSize()
        return MediaFingerprint(
            fileName: fileName,
            fileHash: md5Hex(data),
            fileSize: size,
            videoDuration: Int(duration.rounded())
        )
    }

    /// 计算数据的 MD5 并转成小写十六进制字符串
    static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
