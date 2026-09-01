import Foundation

#if os(iOS)
import UIKit

/// 使用系统场景几何请求切换播放器横竖屏。
@MainActor
enum PlayerOrientationController {
    /// 场景方向请求已返回但界面未切换到目标方向。
    private struct OrientationNotAppliedError: LocalizedError {
        var errorDescription: String? { "系统未完成屏幕方向切换，请确认已关闭设备方向锁定" }
    }

    /// 请求播放器进入横屏或恢复竖屏。
    /// - Parameters:
    ///   - landscape: true 表示横屏全屏，false 表示竖屏。
    ///   - completion: 系统实际到达目标方向后的结果回调。
    static func requestLandscape(_ landscape: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            completion(.failure(OrientationNotAppliedError()))
            return
        }
        let mask: UIInterfaceOrientationMask = landscape ? .landscape : .portrait
        var completionDelivered = false
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            Task { @MainActor in
                guard !completionDelivered else { return }
                completionDelivered = true
                completion(.failure(error))
            }
        }
        Task { @MainActor in
            for _ in 0..<24 {
                try? await Task.sleep(for: .milliseconds(50))
                let matches = landscape
                    ? scene.interfaceOrientation.isLandscape
                    : scene.interfaceOrientation.isPortrait
                guard !completionDelivered else { return }
                if matches {
                    completionDelivered = true
                    completion(.success(()))
                    return
                }
            }
            guard !completionDelivered else { return }
            completionDelivered = true
            completion(.failure(OrientationNotAppliedError()))
        }
    }

    /// 读取当前前台场景是否处于横屏。
    /// - Returns: 当前界面方向是横屏时返回 true。
    static func isLandscape() -> Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .interfaceOrientation.isLandscape == true
    }
}
#endif

/// 播放器可选择的一条音频或字幕轨道。
struct MediaTrackOption: Identifiable, Hashable {
    let id: String
    let title: String
}

/// 播放页展示的媒体基础信息。
struct PlaybackMediaInfo: Equatable {
    var resolution = "未知"
    var duration = "--:--"
    var source = "本地文件"
}

/// 本机断点续播存储；只保存轻量时间信息，不复制视频数据。
enum PlaybackProgressStore {
    private static let storageKey = "playback.progress.v1"

    private struct Entry: Codable {
        let position: Double
        let duration: Double
        let updatedAt: Date
    }

    /// 供媒体库展示的只读播放进度摘要。
    struct Snapshot: Equatable {
        let position: Double
        let duration: Double
        let updatedAt: Date

        /// 当前视频已播放的 0...1 比例。
        var fraction: Double {
            guard duration > 0 else { return 0 }
            return min(max(position / duration, 0), 1)
        }
    }

    /// 读取尚未接近片尾的续播位置。
    /// - Parameters:
    ///   - mediaKey: 媒体稳定标识。
    ///   - duration: 当前探测到的视频时长。
    /// - Returns: 可恢复的位置；开头、片尾或记录过旧时返回 nil。
    static func position(for mediaKey: String, duration: Double) -> Double? {
        guard let entry = loadEntries()[mediaKey],
              Date().timeIntervalSince(entry.updatedAt) < 180 * 86_400,
              entry.position >= 15,
              entry.position < max(duration - 20, 15) else {
            return nil
        }
        return min(entry.position, duration)
    }

    /// 读取媒体库卡片需要的播放进度摘要。
    /// - Parameter mediaKey: 媒体稳定标识。
    /// - Returns: 仍处于有效续播区间的进度；无记录时返回 nil。
    static func snapshot(for mediaKey: String) -> Snapshot? {
        guard let entry = loadEntries()[mediaKey],
              Date().timeIntervalSince(entry.updatedAt) < 180 * 86_400,
              entry.position >= 5,
              entry.duration > 0,
              entry.position < max(entry.duration - 20, 15) else {
            return nil
        }
        return Snapshot(
            position: min(entry.position, entry.duration),
            duration: entry.duration,
            updatedAt: entry.updatedAt
        )
    }

    /// 保存当前播放进度；接近片尾时删除记录，下一次从头播放。
    /// - Parameters:
    ///   - position: 当前播放秒数。
    ///   - duration: 视频总时长。
    ///   - mediaKey: 媒体稳定标识。
    static func save(position: Double, duration: Double, for mediaKey: String) {
        guard position.isFinite, duration.isFinite, duration > 0 else { return }
        var entries = loadEntries()
        if position >= duration - 20 {
            entries.removeValue(forKey: mediaKey)
        } else if position >= 5 {
            entries[mediaKey] = Entry(position: position, duration: duration, updatedAt: Date())
        }
        if entries.count > 200 {
            let keep = entries.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(200)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        persist(entries)
    }

    /// 删除某个视频的断点记录。
    /// - Parameter mediaKey: 媒体稳定标识。
    static func remove(for mediaKey: String) {
        var entries = loadEntries()
        entries.removeValue(forKey: mediaKey)
        persist(entries)
    }

    /// 从 UserDefaults 解码全部进度记录。
    /// - Returns: 解码失败时返回空字典。
    private static func loadEntries() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return [:]
        }
        return entries
    }

    /// 编码并写入全部进度记录。
    /// - Parameter entries: 最新记录。
    private static func persist(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

/// 用户为同一剧集合集记录的片头结束与片尾开始位置。
struct PlaybackSkipSegment: Codable, Equatable {
    var introEnd: Double?
    var outroStart: Double?
}

/// 本机片头片尾时间存储，按合集或节目标题复用到各分集。
enum PlaybackSkipSegmentStore {
    private static let storageKey = "playback.skip-segments.v1"

    /// 读取指定合集的跳过位置。
    /// - Parameter key: 合集 ID 或节目标题。
    /// - Returns: 已保存的片头片尾位置；无记录时返回空配置。
    static func segment(for key: String) -> PlaybackSkipSegment {
        load()[key] ?? PlaybackSkipSegment()
    }

    /// 保存或删除指定合集的跳过位置。
    /// - Parameters:
    ///   - segment: 最新片头片尾配置。
    ///   - key: 合集 ID 或节目标题。
    static func save(_ segment: PlaybackSkipSegment, for key: String) {
        var values = load()
        if segment.introEnd == nil, segment.outroStart == nil {
            values.removeValue(forKey: key)
        } else {
            values[key] = segment
        }
        guard let data = try? JSONEncoder().encode(values) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// 解码全部片头片尾记录。
    /// - Returns: 解码失败时返回空字典。
    private static func load() -> [String: PlaybackSkipSegment] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let values = try? JSONDecoder().decode([String: PlaybackSkipSegment].self, from: data) else {
            return [:]
        }
        return values
    }
}
