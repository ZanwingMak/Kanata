import Foundation
import KanataCore

/// 轨道分配与防重叠（FR-DMK-102）。
/// 滚动弹幕需要同时满足两个条件才能进入某条轨道：
///   1. 上一条弹幕的尾部已完全进入屏幕；
///   2. 新弹幕不会在上一条离开屏幕前追上它。
struct TrackAllocator {
    /// 轨道上最后一条弹幕的运动信息
    private struct Occupancy {
        /// 进入屏幕的时间
        let enterTime: Double
        /// 弹幕宽度
        let width: Double
        /// 速度（点/秒）
        let speed: Double
        /// 完全离开屏幕的时间
        let leaveTime: Double
    }

    private var scrollTracks: [Occupancy?] = []
    private var topTracks: [Double] = []      // 每轨的占用截止时间
    private var bottomTracks: [Double] = []

    /// 重建轨道数组。视图尺寸或配置变化时调用
    mutating func reset(trackCount: Int) {
        let count = max(trackCount, 1)
        scrollTracks = Array(repeating: nil, count: count)
        topTracks = Array(repeating: -1, count: count)
        bottomTracks = Array(repeating: -1, count: count)
    }

    var trackCount: Int { scrollTracks.count }

    /// 为滚动弹幕分配轨道
    /// - Parameters:
    ///   - now: 当前播放时间
    ///   - width: 弹幕宽度
    ///   - screenWidth: 视图宽度
    ///   - duration: 穿屏时长
    /// - Returns: 轨道序号，无可用轨道时返回 nil
    mutating func allocateScroll(
        now: Double,
        width: Double,
        screenWidth: Double,
        duration: Double
    ) -> Int? {
        let speed = (screenWidth + width) / duration
        let leaveTime = now + duration
        for index in scrollTracks.indices {
            guard let occupied = scrollTracks[index] else {
                scrollTracks[index] = Occupancy(enterTime: now, width: width, speed: speed, leaveTime: leaveTime)
                return index
            }
            // 条件 1：上一条尾部已进入屏幕
            let elapsed = now - occupied.enterTime
            guard occupied.speed * elapsed >= occupied.width else { continue }
            // 条件 2：新弹幕不会追上上一条
            guard occupied.leaveTime <= now + (screenWidth + width) / speed else { continue }
            scrollTracks[index] = Occupancy(enterTime: now, width: width, speed: speed, leaveTime: leaveTime)
            return index
        }
        return nil
    }

    /// 为顶部弹幕分配轨道，从上往下找第一条空闲轨道
    mutating func allocateTop(now: Double, duration: Double) -> Int? {
        for index in topTracks.indices where topTracks[index] <= now {
            topTracks[index] = now + duration
            return index
        }
        return nil
    }

    /// 为底部弹幕分配轨道，从下往上找第一条空闲轨道
    mutating func allocateBottom(now: Double, duration: Double) -> Int? {
        for index in bottomTracks.indices.reversed() where bottomTracks[index] <= now {
            bottomTracks[index] = now + duration
            return index
        }
        return nil
    }
}
