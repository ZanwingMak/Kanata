import Foundation

/// 单个合集的用户编排结果；忽略不会删除原媒体文件。
struct CollectionLayout: Codable, Equatable {
    var orderedItemIDs: [String] = []
    var ignoredItemIDs: Set<String> = []
}

/// 保存剧集自定义排序与忽略状态。
enum CollectionLayoutStore {
    private static let storageKey = "library.collection-layouts.v1"

    /// 读取指定合集布局。
    /// - Parameter collectionID: 合集稳定标识。
    /// - Returns: 未编辑过时返回空布局。
    static func layout(for collectionID: String) -> CollectionLayout {
        load()[collectionID] ?? CollectionLayout()
    }

    /// 按用户顺序返回合集条目，并按需过滤忽略项。
    /// - Parameters:
    ///   - items: 合集原始条目。
    ///   - collectionID: 合集稳定标识。
    ///   - includesIgnored: 是否保留被忽略的条目。
    /// - Returns: 自定义顺序后的条目。
    static func ordered(
        _ items: [LibraryItem],
        collectionID: String,
        includesIgnored: Bool = false
    ) -> [LibraryItem] {
        let layout = layout(for: collectionID)
        let positions = Dictionary(uniqueKeysWithValues: layout.orderedItemIDs.enumerated().map { ($0.element, $0.offset) })
        return items
            .filter { includesIgnored || !layout.ignoredItemIDs.contains($0.id) }
            .sorted { left, right in
                let leftPosition = positions[left.id]
                let rightPosition = positions[right.id]
                if let leftPosition, let rightPosition, leftPosition != rightPosition {
                    return leftPosition < rightPosition
                }
                if leftPosition != nil { return true }
                if rightPosition != nil { return false }
                return LibraryItem.collectionOrder(left, right)
            }
    }

    /// 保存当前完整顺序。
    /// - Parameters:
    ///   - items: 已完成排序的条目。
    ///   - collectionID: 合集稳定标识。
    static func saveOrder(_ items: [LibraryItem], collectionID: String) {
        var values = load()
        var layout = values[collectionID] ?? CollectionLayout()
        layout.orderedItemIDs = items.map(\.id)
        values[collectionID] = layout
        persist(values)
    }

    /// 切换某一集的忽略状态。
    /// - Parameters:
    ///   - itemID: 媒体条目 ID。
    ///   - collectionID: 合集稳定标识。
    static func toggleIgnored(itemID: String, collectionID: String) {
        var values = load()
        var layout = values[collectionID] ?? CollectionLayout()
        if layout.ignoredItemIDs.contains(itemID) {
            layout.ignoredItemIDs.remove(itemID)
        } else {
            layout.ignoredItemIDs.insert(itemID)
        }
        values[collectionID] = layout
        persist(values)
    }

    /// 把某条目的忽略状态设置为明确值。
    /// - Parameters:
    ///   - itemID: 媒体条目 ID。
    ///   - collectionID: 合集稳定标识。
    ///   - shouldIgnore: 是否应被忽略。
    static func toggleIgnoredIfNeeded(
        itemID: String,
        collectionID: String,
        shouldIgnore: Bool
    ) {
        var values = load()
        var layout = values[collectionID] ?? CollectionLayout()
        if shouldIgnore {
            layout.ignoredItemIDs.insert(itemID)
        } else {
            layout.ignoredItemIDs.remove(itemID)
        }
        values[collectionID] = layout
        persist(values)
    }

    /// 删除合集布局，通常在整个合集移出媒体库时调用。
    /// - Parameter collectionID: 合集稳定标识。
    static func remove(collectionID: String) {
        var values = load()
        values.removeValue(forKey: collectionID)
        persist(values)
    }

    /// 导出 iCloud 同步使用的原始布局数据。
    /// - Returns: JSON 编码失败时返回 nil。
    static func exportData() -> Data? {
        try? JSONEncoder().encode(load())
    }

    /// 从 iCloud 快照替换本地布局。
    /// - Parameter data: JSON 编码的布局字典。
    static func importData(_ data: Data?) {
        guard let data,
              let values = try? JSONDecoder().decode([String: CollectionLayout].self, from: data) else { return }
        persist(values, schedulesCloudPush: false)
    }

    /// 解码全部合集布局。
    /// - Returns: 无数据或损坏时返回空字典。
    private static func load() -> [String: CollectionLayout] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let values = try? JSONDecoder().decode([String: CollectionLayout].self, from: data) else {
            return [:]
        }
        return values
    }

    /// 编码并保存布局字典。
    /// - Parameters:
    ///   - values: 最新布局。
    ///   - schedulesCloudPush: 是否安排 iCloud 上传。
    private static func persist(
        _ values: [String: CollectionLayout],
        schedulesCloudPush: Bool = true
    ) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        if schedulesCloudPush {
            Task { @MainActor in CloudSyncStore.shared.noteLocalChange() }
        }
    }
}
