import Foundation
import SwiftUI

/// 目录扫描后的待确认媒体集合。
struct MediaImportDraft: Identifiable {
    let id = UUID()
    let title: String
    let items: [LibraryItem]
    let prefersMergedCollection: Bool
}

/// 本次导入中的独立候选，避免多个别名或相同地址共享选中状态。
private struct MediaImportCandidate: Identifiable, Hashable {
    let id: String
    var item: LibraryItem
    var isIncluded: Bool
}

/// 导入预览中展示的一组候选视频。
private struct MediaImportGroup: Identifiable {
    let id: String
    let title: String
    let items: [MediaImportCandidate]
}

/// 在写入媒体库前提供分组、去重、季集标注、排序和忽略操作。
struct MediaImportPreview: View {
    let draft: MediaImportDraft
    let usesParentNavigation: Bool
    let onConfirm: ([LibraryItem]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [MediaImportCandidate]
    @State private var mergesCollections: Bool
    @State private var mergedTitle: String
    @State private var editingCandidate: MediaImportCandidate?

    /// 创建导入预览，并为每个扫描结果生成本次导入内唯一的候选 ID。
    /// - Parameters:
    ///   - draft: 扫描结果。
    ///   - usesParentNavigation: 是否复用上层导航栈。
    ///   - onConfirm: 用户确认后的条目回调。
    init(
        draft: MediaImportDraft,
        usesParentNavigation: Bool = false,
        onConfirm: @escaping ([LibraryItem]) -> Void
    ) {
        self.draft = draft
        self.usesParentNavigation = usesParentNavigation
        self.onConfirm = onConfirm
        _candidates = State(initialValue: draft.items.enumerated().map { offset, item in
            MediaImportCandidate(id: "candidate:\(offset):\(item.id)", item: item, isIncluded: true)
        })
        _mergesCollections = State(
            initialValue: draft.prefersMergedCollection || Self.containsOnlySeasonDirectories(draft.items)
        )
        _mergedTitle = State(initialValue: draft.title)
    }

    /// 按扫描来源生成原始分组，避免重新计算时丢失用户排序。
    private var sourceGroups: [MediaImportGroup] {
        var order: [String] = []
        var values: [String: [MediaImportCandidate]] = [:]
        var titles: [String: String] = [:]
        for candidate in candidates {
            let id = groupID(for: candidate)
            if values[id] == nil { order.append(id) }
            values[id, default: []].append(candidate)
            titles[id] = resolvedGroupTitle(candidate.item.collectionTitle ?? "单个视频")
        }
        return order.map { id in
            MediaImportGroup(id: id, title: titles[id] ?? "单个视频", items: values[id] ?? [])
        }
    }

    /// 返回当前导入模式下的可编辑列表；合并时允许跨目录统一排序。
    private var groups: [MediaImportGroup] {
        guard mergesCollections else { return sourceGroups }
        let title = mergedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return [MediaImportGroup(
            id: mergedGroupID,
            title: title.isEmpty ? draft.title : title,
            items: candidates
        )]
    }

    /// 本次合并列表使用的临时分组 ID。
    private var mergedGroupID: String { "merged-import:\(draft.id.uuidString)" }

    /// 当前参与导入的视频数量。
    private var selectedCount: Int { candidates.filter(\.isIncluded).count }

    /// 当前是否已经选中扫描结果中的全部条目。
    private var allItemsSelected: Bool { candidates.allSatisfy(\.isIncluded) }

    /// 顶部全局选择按钮的明确文案。
    private var allSelectionTitle: String { allItemsSelected ? "取消全选全部" : "全选全部" }

    /// 当前选中项中按实际播放地址计算出的完全重复数量。
    private var duplicateCount: Int {
        var identities: Set<String> = []
        return candidates.filter(\.isIncluded).reduce(into: 0) { count, candidate in
            if !identities.insert(contentIdentity(for: candidate.item)).inserted { count += 1 }
        }
    }

    /// 返回季集号相同的冲突候选 ID，相同文件去重与集数冲突分别处理。
    private var conflictingCandidateIDs: Set<String> {
        var buckets: [String: [String]] = [:]
        for candidate in candidates where candidate.isIncluded {
            guard let episode = candidate.item.episode else { continue }
            let key = "\(activeGroupID(for: candidate)):\(candidate.item.season ?? 1):\(episode)"
            buckets[key, default: []].append(candidate.id)
        }
        return Set(buckets.values.filter { $0.count > 1 }.flatMap { $0 })
    }

    @ViewBuilder
    var body: some View {
        if usesParentNavigation {
            content
        } else {
            NavigationStack { content }
        }
    }

    /// 构建可由 iOS 弹窗和 tvOS 全屏导航共同复用的导入编排列表。
    private var content: some View {
        List {
            Section {
                KanataRowLabel(
                    title: "已识别 \(draft.items.count) 个视频",
                    detail: "加入前可以排序、修改季集号、去重或忽略，不会自动播放。",
                    symbol: "checklist"
                )
                Button {
                    toggleAll()
                } label: {
                    Label(allSelectionTitle, systemImage: allItemsSelected ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(KanataSecondaryButtonStyle())
                if duplicateCount > 0 {
                    Button {
                        ignoreExactDuplicates()
                    } label: {
                        Label("忽略 \(duplicateCount) 个重复文件", systemImage: "square.on.square.dashed")
                    }
                    .buttonStyle(KanataSecondaryButtonStyle())
                }
                if sourceGroups.count > 1 {
                    Toggle("把所有目录合并为一个合集", isOn: $mergesCollections)
                    if mergesCollections {
                        TextField("合集名称", text: $mergedTitle)
                    }
                    Text(mergesCollections
                        ? "按当前列表顺序合并，手动标注的季集号会用于显示和弹幕匹配。"
                        : "保留季度或目录分组；季度目录会使用“作品名 · 第 N 季”作为合集标题。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(groups) { group in
                Section {
                    Button {
                        toggleGroup(group.id)
                    } label: {
                        Label(
                            selectionTitle(for: group),
                            systemImage: groupItemsSelected(group) ? "checkmark.circle.fill" : "circle"
                        )
                    }
                    .buttonStyle(KanataSecondaryButtonStyle())
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { offset, candidate in
                        candidateRow(candidate, position: offset + 1, group: group)
                    }
                    .onMove { source, destination in
                        move(in: group.id, from: source, to: destination)
                    }
                } header: {
                    Text(group.title)
                } footer: {
                    Text("序号表示播放顺序；“第几集”可以单独修改。")
                }
            }
        }
        .listStyle(.plain)
        .kanataFormBackground()
        .navigationTitle("确认导入")
        .kanataInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
                    .kanataToolbarTextButton()
            }
            #if !os(tvOS)
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            #endif
            ToolbarItem(placement: .confirmationAction) {
                Button("加入 \(selectedCount) 项") { confirmImport() }
                    .kanataToolbarTextButton()
                    .disabled(selectedCount == 0)
            }
        }
        .tint(KanataTheme.accent)
        #if os(tvOS)
        .navigationDestination(item: $editingCandidate) { candidate in
            EpisodeMetadataEditor(candidate: candidate, onSave: updateEpisode)
        }
        #else
        .kanataModal(item: $editingCandidate) { candidate in
            NavigationStack {
                EpisodeMetadataEditor(candidate: candidate, onSave: updateEpisode)
            }
        }
        #endif
    }

    /// 构建一个候选视频行及其独立管理菜单。
    /// - Parameters:
    ///   - candidate: 本次导入候选。
    ///   - position: 当前分组内的播放顺序。
    ///   - group: 候选所属分组。
    /// - Returns: 可聚焦、可独立选择的候选行。
    private func candidateRow(
        _ candidate: MediaImportCandidate,
        position: Int,
        group: MediaImportGroup
    ) -> some View {
        HStack(spacing: 10) {
            Button {
                toggleSelection(candidate.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: candidate.isIncluded ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(candidate.isIncluded ? KanataTheme.accent : .secondary)
                    Text("\(position)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(candidate.item.episodeLabel ?? "集数未标注")
                                .foregroundStyle(.primary)
                                #if os(tvOS)
                                .font(.title3.weight(.semibold))
                                #endif
                            if conflictingCandidateIDs.contains(candidate.id) {
                                Label("集数冲突", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(KanataTheme.warning)
                            }
                        }
                        Text(candidate.item.displayName)
                            #if os(tvOS)
                            .font(.body)
                            #else
                            .font(.caption)
                            #endif
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if !candidate.isIncluded {
                        Text("已忽略")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: importRowHeight, alignment: .leading)
                .padding(.horizontal, 14)
                .background(KanataTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
            }
            .kanataTVFocus(cornerRadius: 12)
            Menu {
                Button("修改季集号", systemImage: "number") { editingCandidate = candidate }
                Button("上移", systemImage: "arrow.up") {
                    move(candidateID: candidate.id, groupID: group.id, delta: -1)
                }
                .disabled(position == 1)
                Button("下移", systemImage: "arrow.down") {
                    move(candidateID: candidate.id, groupID: group.id, delta: 1)
                }
                .disabled(position == group.items.count)
                Button(
                    candidate.isIncluded ? "从本次导入忽略" : "恢复导入",
                    systemImage: candidate.isIncluded ? "eye.slash" : "eye"
                ) {
                    toggleSelection(candidate.id)
                }
            } label: {
                #if os(tvOS)
                Label("编辑", systemImage: "slider.horizontal.3")
                    .font(.headline.weight(.semibold))
                    .frame(minWidth: 140, minHeight: 64)
                #else
                Image(systemName: "ellipsis.circle")
                    .frame(width: 48, height: 48)
                #endif
            }
            .background(KanataTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .kanataTVFocus(cornerRadius: 12)
            .accessibilityLabel("管理 \(candidate.item.displayName)")
        }
        .listRowBackground(Color.clear)
        #if !os(tvOS)
        .listRowSeparator(.hidden)
        #endif
    }

    /// 切换单个候选是否参与本次导入。
    /// - Parameter id: 本次导入候选 ID。
    private func toggleSelection(_ id: String) {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        candidates[index].isIncluded.toggle()
    }

    /// 切换本次扫描结果中的全部候选。
    private func toggleAll() {
        let value = !allItemsSelected
        for index in candidates.indices { candidates[index].isIncluded = value }
    }

    /// 切换一个扫描分组的全选状态。
    /// - Parameter groupID: 当前目录分组 ID。
    private func toggleGroup(_ groupID: String) {
        let shouldInclude = candidates
            .filter { self.candidate($0, belongsTo: groupID) }
            .contains { !$0.isIncluded }
        for index in candidates.indices where self.candidate(candidates[index], belongsTo: groupID) {
            candidates[index].isIncluded = shouldInclude
        }
    }

    /// 返回分组标题区域的全选操作文案。
    /// - Parameter group: 当前目录分组。
    /// - Returns: 明确标注只影响当前目录列表的操作文案。
    private func selectionTitle(for group: MediaImportGroup) -> String {
        groupItemsSelected(group) ? "取消全选当前列表" : "全选当前列表"
    }

    /// 判断当前目录列表中的条目是否已经全部选中。
    /// - Parameter group: 当前目录分组。
    /// - Returns: 全部已选中时返回 true。
    private func groupItemsSelected(_ group: MediaImportGroup) -> Bool {
        group.items.allSatisfy(\.isIncluded)
    }

    /// 返回候选所属的稳定分组 ID。
    /// - Parameter candidate: 本次导入候选。
    /// - Returns: 合集 ID；单文件使用候选 ID 隔离。
    private func groupID(for candidate: MediaImportCandidate) -> String {
        candidate.item.collectionID ?? "single:\(candidate.id)"
    }

    /// 返回候选在当前合并模式下所在的可见分组 ID。
    /// - Parameter candidate: 本次导入候选。
    /// - Returns: 合并模式统一返回临时分组，否则返回原目录分组。
    private func activeGroupID(for candidate: MediaImportCandidate) -> String {
        mergesCollections ? mergedGroupID : groupID(for: candidate)
    }

    /// 判断候选是否属于指定的当前可见分组。
    /// - Parameters:
    ///   - candidate: 本次导入候选。
    ///   - groupID: 当前界面分组 ID。
    /// - Returns: 候选属于该列表时返回 true。
    private func candidate(_ candidate: MediaImportCandidate, belongsTo groupID: String) -> Bool {
        activeGroupID(for: candidate) == groupID
    }

    /// 返回用于识别同一底层文件的键。
    /// - Parameter item: 待比较的媒体条目。
    /// - Returns: 网络地址优先，否则使用本地稳定条目 ID。
    private func contentIdentity(for item: LibraryItem) -> String {
        if let url = item.remoteURLString { return "remote:\(url)" }
        return item.id
    }

    /// 判断扫描结果是否全部来自无作品上下文的季度目录，以便默认合并为作品合集。
    /// - Parameter items: 本次扫描得到的媒体条目。
    /// - Returns: 至少包含两个季度目录且所有目录都可识别为季度时返回 true。
    private static func containsOnlySeasonDirectories(_ items: [LibraryItem]) -> Bool {
        let titles = Set(items.compactMap(\.collectionTitle))
        return titles.count > 1 && titles.allSatisfy { seasonDirectoryLabel(for: $0) != nil }
    }

    /// 把缺少作品上下文的季度目录规范为用户可理解的季标题。
    /// - Parameter rawTitle: 媒体源返回的原始目录标题。
    /// - Returns: `第 N 季`、`特别篇`，或无法识别时返回 nil。
    private static func seasonDirectoryLabel(for rawTitle: String) -> String? {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let specialPattern = #"(?i)^(?:specials?|ova|oad|sp|特别篇|特別篇)$"#
        if title.range(of: specialPattern, options: .regularExpression) != nil { return "特别篇" }
        let patterns = [
            #"(?i)^(?:season|series|s)\s*0*(\d{1,3})$"#,
            #"^第?\s*0*(\d{1,3})\s*[季期部]$"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                      in: title,
                      range: NSRange(title.startIndex..., in: title)
                  ),
                  let range = Range(match.range(at: 1), in: title),
                  let season = Int(title[range]) else { continue }
            return season == 0 ? "特别篇" : "第 \(season) 季"
        }
        return nil
    }

    /// 生成不会在媒体库丢失作品上下文的分组展示标题。
    /// - Parameter rawTitle: 原始目录或媒体服务器分组名称。
    /// - Returns: 季度目录继承作品名后的标题；其他目录保持原名。
    private func resolvedGroupTitle(_ rawTitle: String) -> String {
        let rootTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootTitle.isEmpty,
              rootTitle.caseInsensitiveCompare(groupTitle) != .orderedSame,
              let seasonLabel = Self.seasonDirectoryLabel(for: groupTitle) else {
            return groupTitle.isEmpty ? "单个视频" : groupTitle
        }
        return "\(rootTitle) · \(seasonLabel)"
    }

    /// 忽略每组完全相同播放地址中除首项外的候选。
    private func ignoreExactDuplicates() {
        var identities: Set<String> = []
        for index in candidates.indices where candidates[index].isIncluded {
            let identity = contentIdentity(for: candidates[index].item)
            if !identities.insert(identity).inserted { candidates[index].isIncluded = false }
        }
    }

    /// 响应拖动排序并只重排当前分组。
    /// - Parameters:
    ///   - groupID: 当前目录分组 ID。
    ///   - source: 被移动项索引。
    ///   - destination: 目标索引。
    private func move(in groupID: String, from source: IndexSet, to destination: Int) {
        var groupCandidates = candidates.filter { self.candidate($0, belongsTo: groupID) }
        groupCandidates.move(fromOffsets: source, toOffset: destination)
        replaceGroup(groupID, with: groupCandidates)
    }

    /// 通过菜单把一个候选在当前分组中上移或下移。
    /// - Parameters:
    ///   - candidateID: 本次导入候选 ID。
    ///   - groupID: 当前目录分组 ID。
    ///   - delta: -1 上移，1 下移。
    private func move(candidateID: String, groupID: String, delta: Int) {
        var groupCandidates = candidates.filter { self.candidate($0, belongsTo: groupID) }
        guard let index = groupCandidates.firstIndex(where: { $0.id == candidateID }) else { return }
        let target = min(max(index + delta, 0), groupCandidates.count - 1)
        guard target != index else { return }
        let candidate = groupCandidates.remove(at: index)
        groupCandidates.insert(candidate, at: target)
        replaceGroup(groupID, with: groupCandidates)
    }

    /// 把重排后的分组写回总候选数组，并保持其他分组位置不变。
    /// - Parameters:
    ///   - groupID: 当前目录分组 ID。
    ///   - values: 已完成排序的组内候选。
    private func replaceGroup(_ groupID: String, with values: [MediaImportCandidate]) {
        var offset = 0
        for index in candidates.indices where self.candidate(candidates[index], belongsTo: groupID) {
            candidates[index] = values[offset]
            offset += 1
        }
    }

    /// 保存用户输入的季号与集号，并立即刷新冲突提示。
    /// - Parameters:
    ///   - candidateID: 本次导入候选 ID。
    ///   - season: 可选季号。
    ///   - episode: 必填集号。
    private func updateEpisode(candidateID: String, season: Int?, episode: Int) {
        guard let index = candidates.firstIndex(where: { $0.id == candidateID }) else { return }
        candidates[index].item.season = season
        candidates[index].item.episode = episode
    }

    /// 返回适合电视观看距离的导入条目高度。
    private var importRowHeight: CGFloat {
        #if os(tvOS)
        76
        #else
        52
        #endif
    }

    /// 按当前选择、排序和季集标注整理条目后提交。
    private func confirmImport() {
        let selected = candidates.filter(\.isIncluded).map(\.item)
        let result: [LibraryItem]
        if mergesCollections {
            let title = mergedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = title.isEmpty ? draft.title : title
            let collectionID = "merged:\(draft.id.uuidString)"
            result = selected.enumerated().map { offset, item in
                item.assigningCollection(id: collectionID, title: resolvedTitle, index: offset + 1)
            }
        } else {
            var order: [String] = []
            var grouped: [String: [LibraryItem]] = [:]
            for item in selected {
                let id = item.collectionID ?? "single:\(item.id)"
                if grouped[id] == nil { order.append(id) }
                grouped[id, default: []].append(item)
            }
            result = order.flatMap { id in
                let values = grouped[id] ?? []
                guard values.first?.collectionID != nil else { return values }
                return values.enumerated().map { offset, item in
                    item.assigningCollection(
                        id: item.collectionID,
                        title: resolvedGroupTitle(item.collectionTitle ?? draft.title),
                        index: offset + 1
                    )
                }
            }
        }
        onConfirm(result)
        dismiss()
    }
}

/// 使用独立页面编辑一个导入候选的季号与集号。
private struct EpisodeMetadataEditor: View {
    let candidate: MediaImportCandidate
    let onSave: (String, Int?, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var seasonText: String
    @State private var episodeText: String

    /// 从候选当前标注初始化编辑表单。
    /// - Parameters:
    ///   - candidate: 要修改的导入候选。
    ///   - onSave: 保存后的季集号回调。
    init(
        candidate: MediaImportCandidate,
        onSave: @escaping (String, Int?, Int) -> Void
    ) {
        self.candidate = candidate
        self.onSave = onSave
        _seasonText = State(initialValue: candidate.item.season.map(String.init) ?? "")
        _episodeText = State(initialValue: candidate.item.episode.map(String.init) ?? "")
    }

    var body: some View {
        Form {
            Section("原始文件") {
                Text(candidate.item.displayName)
                    .foregroundStyle(.secondary)
            }
            Section("剧集标注") {
                LabeledContent {
                    TextField("例如 1", text: $seasonText)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("季号")
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("季号")
                        Text("可留空")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent {
                    TextField("例如 1", text: $episodeText)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("集号")
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("集号")
                        Text("必填")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Button("保存季集号") { save() }
                    .buttonStyle(KanataPrimaryButtonStyle())
                    .disabled(validEpisode == nil)
            } footer: {
                Text("手动标注会覆盖自动识别结果，并用于媒体库显示与弹幕匹配。")
            }
        }
        .kanataFormBackground()
        .navigationTitle("修改季集号")
        .kanataInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
                    .kanataToolbarTextButton()
            }
        }
    }

    /// 校验用户输入的正整数集号。
    private var validEpisode: Int? {
        guard let value = Int(episodeText), value > 0, value <= 9_999 else { return nil }
        return value
    }

    /// 校验并提交季集号；季号空白时保持 nil。
    private func save() {
        guard let episode = validEpisode else { return }
        let season = Int(seasonText).flatMap { (0...999).contains($0) ? $0 : nil }
        onSave(candidate.id, season, episode)
        dismiss()
    }
}
