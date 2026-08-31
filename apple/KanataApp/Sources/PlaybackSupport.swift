import Foundation

#if os(iOS)
import UIKit

/// 使用系统场景几何请求切换播放器横竖屏。
@MainActor
enum PlayerOrientationController {
    /// 请求播放器进入横屏或恢复竖屏。
    /// - Parameters:
    ///   - landscape: true 表示横屏全屏，false 表示竖屏。
    ///   - onError: 系统拒绝方向切换时的错误回调。
    static func requestLandscape(_ landscape: Bool, onError: @escaping (Error) -> Void) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        let mask: UIInterfaceOrientationMask = landscape ? .landscape : .portrait
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            Task { @MainActor in onError(error) }
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
