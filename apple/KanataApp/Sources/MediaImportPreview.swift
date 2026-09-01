import SwiftUI

/// 目录扫描后的待确认媒体集合。
struct MediaImportDraft: Identifiable {
    let id = UUID()
    let title: String
    let items: [LibraryItem]
    let prefersMergedCollection: Bool
}

/// 导入预览中展示的一组候选视频。
private struct MediaImportGroup: Identifiable {
    let id: String
    let title: String
    let items: [LibraryItem]
}

/// 在写入媒体库前提供分组预览、多选和合并策略。
struct MediaImportPreview: View {
    let draft: MediaImportDraft
    let onConfirm: ([LibraryItem]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<String>
    @State private var mergesCollections: Bool
    @State private var mergedTitle: String

    /// 创建导入预览并默认选中扫描到的全部视频。
    /// - Parameters:
    ///   - draft: 扫描结果。
    ///   - onConfirm: 用户确认后的条目回调。
    init(draft: MediaImportDraft, onConfirm: @escaping ([LibraryItem]) -> Void) {
        self.draft = draft
        self.onConfirm = onConfirm
        _selectedIDs = State(initialValue: Set(draft.items.map(\.id)))
        _mergesCollections = State(initialValue: draft.prefersMergedCollection)
        _mergedTitle = State(initialValue: draft.title)
    }

    /// 按扫描阶段生成的合集归属分组展示。
    private var groups: [MediaImportGroup] {
        let grouped = Dictionary(grouping: draft.items) { item in
            item.collectionID ?? "single:\(item.id)"
        }
        return grouped.map { id, items in
            MediaImportGroup(
                id: id,
                title: items.first?.collectionTitle ?? "单个视频",
                items: items.sorted(by: LibraryItem.collectionOrder)
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// 当前被选中的视频数量。
    private var selectedCount: Int { selectedIDs.count }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    KanataRowLabel(
                        title: "已识别 \(draft.items.count) 个视频",
                        detail: "确认分组和集数后再加入媒体库，不会自动播放。",
                        symbol: "checklist"
                    )
                    if groups.count > 1 {
                        Toggle("合并为一个合集", isOn: $mergesCollections)
                        if mergesCollections {
                            TextField("合集名称", text: $mergedTitle)
                        }
                    }
                }
                ForEach(groups) { group in
                    Section {
                        ForEach(group.items) { item in
                            Button {
                                toggleSelection(item.id)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedIDs.contains(item.id) ? KanataTheme.accent : .secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.episodeLabel ?? item.displayName)
                                            .foregroundStyle(.primary)
                                        Text(item.displayName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack {
                            Text(group.title)
                            Spacer()
                            Button(selectionTitle(for: group.items)) {
                                toggleGroup(group.items)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("确认导入")
            .kanataInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("加入 \(selectedCount) 项") { confirmImport() }
                        .disabled(selectedIDs.isEmpty)
                }
            }
        }
        .tint(KanataTheme.accent)
    }

    /// 切换单个视频是否参与本次导入。
    /// - Parameter id: 视频条目 ID。
    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    /// 切换一个扫描分组的全选状态。
    /// - Parameter items: 分组内条目。
    private func toggleGroup(_ items: [LibraryItem]) {
        let ids = Set(items.map(\.id))
        if ids.isSubset(of: selectedIDs) {
            selectedIDs.subtract(ids)
        } else {
            selectedIDs.formUnion(ids)
        }
    }

    /// 返回分组标题区域的全选操作文案。
    /// - Parameter items: 分组内条目。
    /// - Returns: 已全选时为“取消全选”，否则为“全选”。
    private func selectionTitle(for items: [LibraryItem]) -> String {
        Set(items.map(\.id)).isSubset(of: selectedIDs) ? "取消全选" : "全选"
    }

    /// 整理选中条目的合集与集数后提交。
    private func confirmImport() {
        let selected = draft.items.filter { selectedIDs.contains($0.id) }
        let result: [LibraryItem]
        if mergesCollections {
            let title = mergedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = title.isEmpty ? draft.title : title
            let collectionID = "merged:\(draft.id.uuidString)"
            result = selected
                .sorted(by: LibraryItem.collectionOrder)
                .enumerated()
                .map { offset, item in
                    item.assigningCollection(id: collectionID, title: resolvedTitle, index: offset + 1)
                }
        } else {
            let grouped = Dictionary(grouping: selected) { $0.collectionID ?? "single:\($0.id)" }
            result = grouped.values.flatMap { values in
                let sorted = values.sorted(by: LibraryItem.collectionOrder)
                guard sorted.first?.collectionID != nil else { return sorted }
                return sorted.enumerated().map { offset, item in
                    item.assigningCollection(
                        id: item.collectionID,
                        title: item.collectionTitle,
                        index: offset + 1
                    )
                }
            }
        }
        onConfirm(result.sorted(by: LibraryItem.collectionOrder))
        dismiss()
    }
}
