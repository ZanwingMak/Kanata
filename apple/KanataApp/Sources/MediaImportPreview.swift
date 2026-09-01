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
    let usesParentNavigation: Bool
    let onConfirm: ([LibraryItem]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<String>
    @State private var mergesCollections: Bool
    @State private var mergedTitle: String

    /// 创建导入预览并默认选中扫描到的全部视频。
    /// - Parameters:
    ///   - draft: 扫描结果。
    ///   - onConfirm: 用户确认后的条目回调。
    init(
        draft: MediaImportDraft,
        usesParentNavigation: Bool = false,
        onConfirm: @escaping ([LibraryItem]) -> Void
    ) {
        self.draft = draft
        self.usesParentNavigation = usesParentNavigation
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

    /// 当前是否已经选中扫描结果中的全部条目。
    private var allItemsSelected: Bool {
        Set(draft.items.map(\.id)).isSubset(of: selectedIDs)
    }

    /// 顶部全局选择按钮的明确文案。
    private var allSelectionTitle: String {
        allItemsSelected ? "取消全选全部" : "全选全部"
    }

    @ViewBuilder
    var body: some View {
        if usesParentNavigation {
            content
        } else {
            NavigationStack { content }
        }
    }

    /// 构建可由 iOS 弹窗和 tvOS 全屏导航共同复用的导入确认列表。
    private var content: some View {
        List {
                Section {
                    KanataRowLabel(
                        title: "已识别 \(draft.items.count) 个视频",
                        detail: "确认分组和集数后再加入媒体库，不会自动播放。",
                        symbol: "checklist"
                    )
                    if groups.count > 1 {
                        Button {
                            toggleAll()
                        } label: {
                            Label(
                                allSelectionTitle,
                                systemImage: allItemsSelected ? "checkmark.circle.fill" : "circle"
                            )
                        }
                        .buttonStyle(KanataSecondaryButtonStyle())
                        Toggle("把所有目录合并为一个合集", isOn: $mergesCollections)
                        if mergesCollections {
                            TextField("合集名称", text: $mergedTitle)
                        }
                        Text(mergesCollections
                            ? "按季度、目录和真实集数重新排序后合并。"
                            : "保留原目录结构，每个目录建立一个独立合集。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(groups) { group in
                    Section {
                        Button {
                            toggleGroup(group.items)
                        } label: {
                            Label(
                                selectionTitle(for: group.items),
                                systemImage: groupItemsSelected(group.items) ? "checkmark.circle.fill" : "circle"
                            )
                        }
                        .buttonStyle(KanataSecondaryButtonStyle())
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
                                            #if os(tvOS)
                                            .font(.title3.weight(.semibold))
                                            #endif
                                        Text(item.displayName)
                                            #if os(tvOS)
                                            .font(.body)
                                            #else
                                            .font(.caption)
                                            #endif
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                }
                                .frame(minHeight: importRowHeight)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .kanataTVFocus(cornerRadius: 12)
                        }
                    } header: { Text(group.title) }
                }
        }
        .navigationTitle("确认导入")
        .kanataInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
                    .kanataToolbarTextButton()
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("加入 \(selectedCount) 项") { confirmImport() }
                    .kanataToolbarTextButton()
                    .disabled(selectedIDs.isEmpty)
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

    /// 切换本次扫描结果中的全部条目，不影响后续重新打开的导入任务。
    private func toggleAll() {
        let ids = Set(draft.items.map(\.id))
        if ids.isSubset(of: selectedIDs) {
            selectedIDs.subtract(ids)
        } else {
            selectedIDs.formUnion(ids)
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
    /// - Returns: 明确标注只影响当前目录列表的操作文案。
    private func selectionTitle(for items: [LibraryItem]) -> String {
        groupItemsSelected(items)
            ? "取消全选当前列表"
            : "全选当前列表"
    }

    /// 判断当前目录列表中的条目是否已经全部选中。
    /// - Parameter items: 当前目录条目。
    /// - Returns: 全部已选中时返回 true。
    private func groupItemsSelected(_ items: [LibraryItem]) -> Bool {
        Set(items.map(\.id)).isSubset(of: selectedIDs)
    }

    /// 返回适合电视观看距离的导入条目高度。
    private var importRowHeight: CGFloat {
        #if os(tvOS)
        72
        #else
        44
        #endif
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
                .sorted(by: LibraryItem.mergedCollectionOrder)
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
        onConfirm(result.sorted(by: LibraryItem.groupedCollectionOrder))
        dismiss()
    }
}
