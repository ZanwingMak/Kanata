import AVFoundation
import KanataCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// 媒体库首页可用的快速筛选条件。
private enum LibraryFilterMode: String, CaseIterable, Identifiable {
    case all
    case local
    case network
    case collection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .local: "本地"
        case .network: "网络"
        case .collection: "剧集合集"
        }
    }
}

/// 媒体库首页可用的排序方式。
private enum LibrarySortMode: String, CaseIterable, Identifiable {
    case added
    case title
    case episode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .added: "添加顺序"
        case .title: "名称"
        case .episode: "剧集顺序"
        }
    }
}

/// 首页“最近添加”统一承载单个视频和整部合集。
private enum RecentLibraryEntry: Identifiable {
    case item(LibraryItem)
    case collection(MediaCollection, Date)

    var id: String {
        switch self {
        case let .item(item): "item:\(item.id)"
        case let .collection(collection, _): "collection:\(collection.id)"
        }
    }

    var addedAt: Date {
        switch self {
        case let .item(item): item.addedAt ?? .distantPast
        case let .collection(_, date): date
        }
    }
}

/// 媒体库首页，统一管理本地文件、网络直链、WebDAV 与媒体服务器条目。
struct LibraryView: View {
    @Environment(AppSettings.self) private var settings
    @State private var isImporting = false
    @State private var isShowingSettings = false
    @State private var items: [LibraryItem] = LibraryStore.load()
    @State private var playing: PlaybackQueue?
    @State private var importError: String?
    @State private var isProcessingImport = false
    @State private var isAddingMediaSource = false
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var mediaSources = MediaSourceProfileStore.load()
    @State private var browsingSource: MediaSourceProfile?
    @State private var progressRevision = 0
    @State private var sourceHealth: [String: MediaSourceHealth] = [:]
    @State private var filterMode = LibraryFilterMode.all
    @State private var sortMode = LibrarySortMode.added
    @State private var favoriteIDs = LibraryFavoriteStore.load()
    @State private var selectedCollectionID: String?
    @State private var libraryNotice: String?
    @State private var pendingLocalImport: MediaImportDraft?
    @State private var recentScrollRequest = 0

    #if os(tvOS)
    private let columns = [GridItem(.adaptive(minimum: 380, maximum: 520), spacing: 34)]
    #else
    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 320), spacing: 16)]
    #endif

    private var libraryHorizontalPadding: CGFloat {
        #if os(tvOS)
        76
        #else
        18
        #endif
    }

    private var librarySectionSpacing: CGFloat {
        #if os(tvOS)
        36
        #else
        18
        #endif
    }

    private var libraryContentMaxWidth: CGFloat {
        #if os(tvOS)
        1760
        #else
        .infinity
        #endif
    }

    /// 按标题与解析信息过滤媒体库。
    private var filteredItems: [LibraryItem] {
        _ = progressRevision
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = items.filter { item in
            let matchesFilter: Bool = switch filterMode {
            case .all: true
            case .local: item.remoteURLString == nil
            case .network: item.remoteURLString != nil
            case .collection: item.collectionID != nil
            }
            let matchesQuery = query.isEmpty
                || item.displayName.localizedCaseInsensitiveContains(query)
                || item.subtitle.localizedCaseInsensitiveContains(query)
            let hidesEpisodeFromDefaultGrid = query.isEmpty
                && filterMode != .collection
                && item.collectionID != nil
            return matchesFilter && matchesQuery && !hidesEpisodeFromDefaultGrid
        }
        switch sortMode {
        case .added:
            return filtered
        case .title:
            return filtered.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .episode:
            return filtered.sorted(by: LibraryItem.collectionOrder)
        }
    }

    /// 按最近播放时间返回仍有有效断点的媒体条目。
    private var continueWatchingItems: [LibraryItem] {
        _ = progressRevision
        return items.compactMap { item -> (LibraryItem, PlaybackProgressStore.Snapshot)? in
            guard let key = item.mediaKey,
                  let snapshot = PlaybackProgressStore.snapshot(for: key) else { return nil }
            return (item, snapshot)
        }
        .sorted { $0.1.updatedAt > $1.1.updatedAt }
        .prefix(12)
        .map(\.0)
    }

    /// 返回仍存在于媒体库中的收藏条目。
    private var favoriteItems: [LibraryItem] {
        items.filter { favoriteIDs.contains($0.id) }
    }

    /// 返回最近加入的单个视频或合集，合集不再拆成大量单集占满栏目。
    private var recentlyAddedEntries: [RecentLibraryEntry] {
        let collectionEntries = mediaCollections.compactMap { collection -> RecentLibraryEntry? in
            guard let date = collection.items.compactMap(\.addedAt).max() else { return nil }
            return .collection(collection, date)
        }
        let itemEntries = items.compactMap { item -> RecentLibraryEntry? in
            guard item.collectionID == nil, item.addedAt != nil else { return nil }
            return .item(item)
        }
        return (collectionEntries + itemEntries)
            .sorted { $0.addedAt > $1.addedAt }
            .prefix(12)
            .map { $0 }
    }

    /// 把媒体库中带合集标识的条目聚合为剧集卡片。
    private var mediaCollections: [MediaCollection] {
        _ = progressRevision
        let grouped = Dictionary(grouping: items.compactMap { item -> LibraryItem? in
            item.collectionID == nil ? nil : item
        }, by: { $0.collectionID ?? "" })
        return grouped.compactMap { id, values in
            guard !id.isEmpty else { return nil }
            let allSorted = CollectionLayoutStore.ordered(
                values,
                collectionID: id,
                includesIgnored: true
            )
            let active = CollectionLayoutStore.ordered(values, collectionID: id)
            guard let first = allSorted.first else { return nil }
            let resumable = active.compactMap { item -> (LibraryItem, Date)? in
                guard let key = item.mediaKey,
                      let snapshot = PlaybackProgressStore.snapshot(for: key) else { return nil }
                return (item, snapshot.updatedAt)
            }
            .max { $0.1 < $1.1 }?.0
            return MediaCollection(
                id: id,
                title: first.collectionTitle ?? first.title,
                items: allSorted,
                nextItem: resumable ?? active.first ?? first
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [KanataTheme.backgroundTop, KanataTheme.background],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                if items.isEmpty && mediaSources.isEmpty {
                    ContentUnavailableView {
                        Label("开始建立你的媒体库", systemImage: "play.rectangle.on.rectangle")
                    } description: {
                        #if os(tvOS)
                        Text("添加 NAS、HLS 或其他可访问的网络视频地址")
                        #else
                        Text("导入本地视频或添加网络地址，Kanata 会边播放边自动匹配弹幕")
                        #endif
                    } actions: {
                        #if !os(tvOS)
                        Button("导入本地视频") { isImporting = true }
                            .buttonStyle(KanataPrimaryButtonStyle())
                            .disabled(isProcessingImport)
                        #endif
                        Button("添加媒体源") { isAddingMediaSource = true }
                            .buttonStyle(KanataSecondaryButtonStyle())
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: librarySectionSpacing) {
                                #if os(tvOS)
                                tvLibraryHeader
                                #endif
                                if !mediaSources.isEmpty {
                                    sourceChannels
                                }
                                if !recentlyAddedEntries.isEmpty && searchText.isEmpty {
                                    recentlyAddedSection
                                        .id("recently-added")
                                }
                                if !continueWatchingItems.isEmpty {
                                    continueWatchingSection
                                }
                                if !favoriteItems.isEmpty && searchText.isEmpty {
                                    favoritesSection
                                }
                                if !mediaCollections.isEmpty && searchText.isEmpty {
                                    collectionSection
                                }
                                HStack(alignment: .firstTextBaseline) {
                                    Text(searchText.isEmpty && filterMode != .collection ? "单个视频" : "视频项目")
                                        .font(.title2.bold())
                                    Spacer()
                                    Text("\(filteredItems.count) 个项目")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                                    ForEach(filteredItems) { item in
                                        mediaCard(item)
                                    }
                                }
                            }
                            .frame(maxWidth: libraryContentMaxWidth, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.horizontal, libraryHorizontalPadding)
                            .padding(.bottom, 60)
                        }
                        .scrollIndicators(.hidden)
                        .onChange(of: recentScrollRequest) { _, value in
                            guard value > 0 else { return }
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(250))
                                withAnimation(.easeInOut(duration: 0.28)) {
                                    proxy.scrollTo("recently-added", anchor: .top)
                                }
                            }
                        }
                    }
                }
            }
            #if os(tvOS)
            .navigationTitle("")
            #else
            .navigationTitle("媒体库")
            #endif
            .kanataLibrarySearch(text: $searchText, isPresented: $isSearching)
            .toolbar {
                #if !os(tvOS)
                ToolbarItem(placement: .topBarLeading) {
                    Button { isShowingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("筛选", selection: $filterMode) {
                            ForEach(LibraryFilterMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        Picker("排序", selection: $sortMode) {
                            ForEach(LibrarySortMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                    } label: {
                        Image(systemName: filterMode == .all ? "arrow.up.arrow.down" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("筛选和排序")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isProcessingImport {
                        ProgressView()
                    } else {
                        Menu {
                            #if !os(tvOS)
                            Button {
                                isImporting = true
                            } label: {
                                Label("导入本地视频", systemImage: "folder.badge.plus")
                            }
                            #endif
                            Button {
                                isAddingMediaSource = true
                            } label: {
                                Label("添加媒体源", systemImage: "network")
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("导入视频和弹幕")
                    }
                }
                #endif
            }
            .kanataFileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie, .item],
                allowsMultipleSelection: true
            ) { result in
                Task { await handleImport(result) }
            }
            .alert(
                "导入失败",
                isPresented: Binding(
                    get: { importError != nil },
                    set: { if !$0 { importError = nil } }
                )
            ) {
                Button("好") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .alert(
                "媒体库已更新",
                isPresented: Binding(
                    get: { libraryNotice != nil },
                    set: { if !$0 { libraryNotice = nil } }
                )
            ) {
                Button("好", role: .cancel) { libraryNotice = nil }
            } message: {
                Text(libraryNotice ?? "")
            }
            .fullScreenCover(item: $playing, onDismiss: {
                progressRevision += 1
            }) { queue in
                if queue.items.contains(where: { $0.resolveURL() != nil }) {
                    PlayerScreen(items: queue.items, initialItemID: queue.initialItemID)
                } else {
                    ContentUnavailableView(
                        "无法访问该文件",
                        systemImage: "exclamationmark.triangle",
                        description: Text("文件可能已被移动或删除，请重新导入")
                    )
                }
            }
            .sheet(item: $pendingLocalImport) { draft in
                MediaImportPreview(draft: draft, onConfirm: addMediaItems)
            }
            #if os(tvOS)
            .sheet(isPresented: $isSearching) {
                TVLibrarySearchSheet(searchText: $searchText)
            }
            .navigationDestination(isPresented: $isShowingSettings) {
                SettingsView(usesParentNavigation: true)
            }
            .navigationDestination(isPresented: $isAddingMediaSource) {
                MediaSourceSheet(
                    onAdd: addMediaItems,
                    onSourcesChanged: reloadMediaSources,
                    usesParentNavigation: true
                )
            }
            .navigationDestination(
                isPresented: Binding(
                    get: { browsingSource != nil },
                    set: { if !$0 { browsingSource = nil } }
                )
            ) {
                if let profile = browsingSource {
                    MediaSourceChannelView(profile: profile, onAdd: addMediaItems)
                }
            }
            #else
            .sheet(isPresented: $isShowingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $isAddingMediaSource) {
                MediaSourceSheet(
                    onAdd: addMediaItems,
                    onSourcesChanged: reloadMediaSources
                )
            }
            .sheet(item: $browsingSource) { profile in
                NavigationStack {
                    MediaSourceChannelView(profile: profile, onAdd: addMediaItems)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("关闭") { browsingSource = nil }
                                    .kanataToolbarTextButton()
                            }
                        }
                }
            }
            #endif
            .navigationDestination(
                isPresented: Binding(
                    get: { selectedCollectionID != nil },
                    set: { if !$0 { selectedCollectionID = nil } }
                )
            ) {
                if let collectionID = selectedCollectionID,
                   let collection = mediaCollections.first(where: { $0.id == collectionID }) {
                    CollectionDetailView(
                        collection: collection,
                        onPlay: { queueItems, item in
                            playing = PlaybackQueue(items: queueItems, initialItemID: item.id)
                        },
                        onRemove: removeItem,
                        onRename: renameCollection,
                        onChanged: { progressRevision += 1 }
                    )
                }
            }
            .task {
                reloadMediaSources()
                await scanDocuments()
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanataCloudDataDidChange)) { _ in
                items = LibraryStore.load()
                reloadMediaSources()
                favoriteIDs = LibraryFavoriteStore.load()
                progressRevision += 1
            }
        }
        .tint(KanataTheme.accent)
    }

    #if os(tvOS)
    /// 构建 Apple TV 首页标题和带文字的主要操作，避免用户猜测小图标含义。
    private var tvLibraryHeader: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("媒体库")
                    .font(.largeTitle.bold())
                Text("选择媒体源、继续观看，或整理剧集合集")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 40)
            Button { isShowingSettings = true } label: {
                Label("设置", systemImage: "gearshape")
            }
            .buttonStyle(KanataTVActionButtonStyle())
            Button { isSearching = true } label: {
                Label("搜索", systemImage: "magnifyingglass")
            }
            .buttonStyle(KanataTVActionButtonStyle())
            Menu {
                Picker("筛选", selection: $filterMode) {
                    ForEach(LibraryFilterMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker("排序", selection: $sortMode) {
                    ForEach(LibrarySortMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            } label: {
                Label("整理", systemImage: "arrow.up.arrow.down")
            }
            .buttonStyle(KanataTVActionButtonStyle())
            Menu {
                Button {
                    isAddingMediaSource = true
                } label: {
                    Label("添加媒体源", systemImage: "network")
                }
            } label: {
                Label("添加", systemImage: "plus")
            }
            .buttonStyle(KanataTVActionButtonStyle())
        }
        .padding(.top, 28)
        .focusSection()
    }
    #endif

    /// 首页“继续观看”横向列表，按最后播放时间排序。
    private var continueWatchingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("继续观看")
                    .font(.title2.bold())
                Spacer()
                Text("自动保存播放位置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(continueWatchingItems) { item in
                        mediaCard(item, showsHistoryContext: true)
                            .frame(width: horizontalCardWidth)
                    }
                }
            }
            .scrollIndicators(.hidden)
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
        }
    }

    /// 首页最近添加横向栏目，新增目录或文件后会自动滚动到这里。
    private var recentlyAddedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近添加")
                    .font(.title2.bold())
                Spacer()
                Text("最新 \(recentlyAddedEntries.count) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(recentlyAddedEntries) { entry in
                        switch entry {
                        case let .item(item):
                            mediaCard(item, showsHistoryContext: true)
                                .frame(width: horizontalCardWidth)
                        case let .collection(collection, _):
                            collectionCard(collection, detail: "最近添加 · 共 \(collection.items.count) 集")
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
        }
    }

    /// 首页收藏横向列表，避免常看的单集或电影被大媒体库淹没。
    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("我的收藏")
                .font(.title2.bold())
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(favoriteItems) { item in
                        mediaCard(item)
                            .frame(width: horizontalCardWidth)
                    }
                }
            }
            .scrollIndicators(.hidden)
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
        }
    }

    /// 首页剧集合集横向列表，点击后从最近断点或第一集进入。
    private var collectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("剧集与合集")
                    .font(.title2.bold())
                Spacer()
                Text("\(mediaCollections.count) 个合集")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(mediaCollections) { collection in
                        collectionCard(collection)
                    }
                }
            }
            .scrollIndicators(.hidden)
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
        }
    }

    /// 生成首页与最近添加栏目共用的合集卡片。
    /// - Parameters:
    ///   - collection: 要展示的合集。
    ///   - detail: 可选副标题；为空时显示续播集数。
    /// - Returns: 可进入合集编排页并支持移除的卡片。
    private func collectionCard(_ collection: MediaCollection, detail: String? = nil) -> some View {
        Button {
            selectedCollectionID = collection.id
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    LinearGradient(
                        colors: [KanataTheme.accentStrong.opacity(0.95), KanataTheme.accent.opacity(0.38)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.white.opacity(0.88))
                }
                .frame(width: collectionCardWidth, height: collectionCardHeight)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    Text("共 \(collection.items.count) 集")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(10)
                }
                Text(collection.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(detail ?? "接着播放 · \(collection.nextItem.episodeLabel ?? collection.nextItem.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: collectionCardWidth, alignment: .leading)
        }
        .kanataTVFocus(cornerRadius: 18)
        .contextMenu {
            Button("从媒体库移除合集", systemImage: "trash", role: .destructive) {
                removeCollection(collection.id)
            }
        }
    }

    /// 首页的媒体服务器频道区域，保留用户已登录的入口。
    private var sourceChannels: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("媒体源")
                    .font(.title2.bold())
                Spacer()
                #if !os(tvOS)
                Button { isAddingMediaSource = true } label: {
                    Label("管理", systemImage: "slider.horizontal.3")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background(KanataTheme.surface, in: Capsule())
                }
                .kanataTVFocus(cornerRadius: 22)
                #endif
            }
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(mediaSources) { profile in
                        Button {
                            browsingSource = profile
                        } label: {
                            HStack(spacing: 16) {
                                Image(systemName: profile.kind.symbol)
                                    #if os(tvOS)
                                    .font(.title.weight(.semibold))
                                    .frame(width: 64, height: 64)
                                    #else
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                                    #endif
                                    .background(KanataTheme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(profile.name)
                                        #if os(tvOS)
                                        .font(.title3.weight(.semibold))
                                        #else
                                        .font(.headline)
                                        #endif
                                        .lineLimit(1)
                                    Text("\(profile.kind.title) · \(profile.subtitle)")
                                        #if os(tvOS)
                                        .font(.body)
                                        #else
                                        .font(.caption)
                                        #endif
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text("最近使用 \(profile.updatedAt.formatted(.relative(presentation: .named)))")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 12)
                                sourceHealthBadge(sourceHealth[profile.id] ?? .checking)
                            }
                            .frame(width: sourceCardWidth, alignment: .leading)
                            .padding(18)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .kanataTVFocus(cornerRadius: 18)
                        .contextMenu {
                            Button("删除登录记录", systemImage: "trash", role: .destructive) {
                                MediaSourceProfileStore.remove(profile)
                                reloadMediaSources()
                            }
                        }
                        .task(id: profile.updatedAt) { await checkSource(profile) }
                    }
                }
            }
            .scrollIndicators(.hidden)
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
        }
    }

    /// 生成媒体源连接状态徽标。
    /// - Parameter health: 最近一次探测状态。
    /// - Returns: 频道卡片右上角的小型状态视图。
    private func sourceHealthBadge(_ health: MediaSourceHealth) -> some View {
        HStack(spacing: 5) {
            if health == .checking {
                ProgressView().controlSize(.mini)
            } else {
                Circle()
                    .fill(health == .online ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
            }
            Text(health.title)
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .foregroundStyle(health == .offline ? Color.red : Color.primary)
        .background(KanataTheme.elevatedSurface, in: Capsule())
    }

    /// 读取媒体源根目录以验证连接与凭证是否仍有效。
    /// - Parameter profile: 要探测的历史连接。
    private func checkSource(_ profile: MediaSourceProfile) async {
        sourceHealth[profile.id] = .checking
        do {
            switch profile.kind {
            case .webDAV:
                guard let server = profile.serverURL,
                      let url = URL(
                          string: profile.rootPath ?? "/",
                          relativeTo: server.appendingPathComponent("")
                      )?.absoluteURL else { throw MediaSourceError.invalidResponse }
                _ = try await WebDAVClient(profile: profile).list(directory: url)
            case .jellyfin, .emby:
                _ = try await MediaBrowserClient().items(profile: profile, parentID: nil)
            case .plex:
                _ = try await PlexClient().items(profile: profile, navigationKey: nil)
            case .synology:
                _ = try await SynologyFileStationClient().items(profile: profile, parentPath: nil)
            }
            sourceHealth[profile.id] = .online
        } catch {
            sourceHealth[profile.id] = .offline
        }
    }

    /// 创建一个带视频缩略图、来源与删除菜单的媒体卡片。
    /// - Parameter item: 媒体库条目。
    /// - Returns: 可点击播放的卡片视图。
    private func mediaCard(_ item: LibraryItem, showsHistoryContext: Bool = false) -> some View {
        let progress = item.mediaKey.flatMap { PlaybackProgressStore.snapshot(for: $0) }
        return Button {
            play(item)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                MediaArtworkView(item: item)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        Label(
                            item.remoteURLString == nil ? "本地" : "网络",
                            systemImage: item.remoteURLString == nil ? "internaldrive" : "network"
                        )
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(10)
                    }
                    .overlay(alignment: .bottom) {
                        if let progress {
                            ProgressView(value: progress.fraction)
                                .progressViewStyle(.linear)
                                .tint(KanataTheme.accent)
                                .scaleEffect(x: 1, y: 1.6, anchor: .center)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 4)
                        }
                    }
                Text(showsHistoryContext ? item.libraryTitle : (item.collectionID == nil ? item.displayName : item.libraryTitle))
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(showsHistoryContext ? item.historySubtitle : item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .kanataTVFocus(cornerRadius: 18)
        .contextMenu {
            Button(
                favoriteIDs.contains(item.id) ? "取消收藏" : "加入收藏",
                systemImage: favoriteIDs.contains(item.id) ? "star.slash" : "star"
            ) {
                toggleFavorite(item)
            }
            Button("从媒体库移除", systemImage: "trash", role: .destructive) {
                removeItem(item)
            }
            if let collectionID = item.collectionID {
                Button("移除整个合集", systemImage: "rectangle.stack.badge.minus", role: .destructive) {
                    removeCollection(collectionID)
                }
            }
        }
        .accessibilityLabel("播放 \(item.displayName)")
    }

    /// 返回首页横向媒体卡片在当前平台上的宽度。
    private var horizontalCardWidth: CGFloat {
        #if os(tvOS)
        420
        #else
        260
        #endif
    }

    /// 返回媒体源频道卡片在当前平台上的宽度。
    private var sourceCardWidth: CGFloat {
        #if os(tvOS)
        520
        #else
        260
        #endif
    }

    /// 返回合集封面在当前平台上的宽度。
    private var collectionCardWidth: CGFloat {
        #if os(tvOS)
        420
        #else
        250
        #endif
    }

    /// 返回合集封面在当前平台上的高度。
    private var collectionCardHeight: CGFloat {
        #if os(tvOS)
        236
        #else
        140
        #endif
    }

    /// 从用户点击的条目构建单视频或同合集播放队列。
    /// - Parameter item: 用户点击的媒体卡片。
    private func play(_ item: LibraryItem) {
        let queueItems: [LibraryItem]
        if let collectionID = item.collectionID {
            queueItems = CollectionLayoutStore.ordered(
                items.filter { $0.collectionID == collectionID },
                collectionID: collectionID
            )
        } else {
            queueItems = [item]
        }
        playing = PlaybackQueue(items: queueItems, initialItemID: item.id)
    }

    /// 切换媒体条目的收藏状态并立即持久化。
    /// - Parameter item: 用户操作的媒体条目。
    private func toggleFavorite(_ item: LibraryItem) {
        if favoriteIDs.contains(item.id) {
            favoriteIDs.remove(item.id)
        } else {
            favoriteIDs.insert(item.id)
        }
        LibraryFavoriteStore.save(favoriteIDs)
    }

    /// 合并新选择的单文件或合集并返回媒体库，不自动开始播放。
    /// - Parameter newItems: 网络媒体源浏览器生成的条目。
    private func addMediaItems(_ newItems: [LibraryItem]) {
        guard !newItems.isEmpty else { return }
        for item in newItems {
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                if let oldAccount = items[index].credentialAccount,
                   oldAccount != item.credentialAccount {
                    KeychainStore.remove(account: oldAccount)
                }
                items[index] = item
            } else {
                items.append(item)
            }
        }
        LibraryStore.save(items)
        for collectionID in Set(newItems.compactMap(\.collectionID)) {
            let collectionItems = items.filter { $0.collectionID == collectionID }
            CollectionLayoutStore.saveOrder(
                collectionItems.sorted(by: LibraryItem.collectionOrder),
                collectionID: collectionID
            )
        }
        progressRevision += 1
        recentScrollRequest += 1
        let collectionCount = Set(newItems.compactMap(\.collectionID)).count
        libraryNotice = collectionCount > 0
            ? "已加入 \(collectionCount) 个合集、共 \(newItems.count) 个视频，并已定位到“最近添加”。"
            : "已加入 \(newItems.count) 个视频，并已定位到“最近添加”。"
    }

    /// 从历史存储刷新首页媒体源频道。
    private func reloadMediaSources() {
        mediaSources = MediaSourceProfileStore.load()
    }

    /// 从媒体库索引移除条目，不删除原始视频文件。
    /// - Parameter item: 待移除的条目。
    private func removeItem(_ item: LibraryItem) {
        if let account = item.credentialAccount {
            KeychainStore.remove(account: account)
        }
        items.removeAll { $0.id == item.id }
        LibraryStore.save(items)
    }

    /// 从媒体库移除同一合集的全部索引项，不删除服务器上的文件。
    /// - Parameter collectionID: 要移除的稳定合集标识。
    private func removeCollection(_ collectionID: String) {
        let accounts = items
            .filter { $0.collectionID == collectionID }
            .compactMap(\.credentialAccount)
        accounts.forEach { KeychainStore.remove(account: $0) }
        items.removeAll { $0.collectionID == collectionID }
        LibraryStore.save(items)
        CollectionLayoutStore.remove(collectionID: collectionID)
    }

    /// 重命名合集内全部条目并立即刷新首页和详情页。
    /// - Parameters:
    ///   - collectionID: 要重命名的合集 ID。
    ///   - title: 用户输入的新名称。
    private func renameCollection(_ collectionID: String, _ title: String) {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        for index in items.indices where items[index].collectionID == collectionID {
            items[index].collectionTitle = value
        }
        LibraryStore.save(items)
        progressRevision += 1
    }

    /// 扫描 App 的 Documents 目录，收录通过文件共享或 AirDrop 放进来的视频（FR-IMP-002）
    private func scanDocuments() async {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: documents,
                  includingPropertiesForKeys: nil
              ) else {
            return
        }
        let danmakuFiles = files.filter(isDanmakuFile)
        var changed = false
        for file in files where isVideoFile(file) {
            if !items.contains(where: { $0.id == file.lastPathComponent }),
               let item = LibraryItem(url: file) {
                items.append(item)
                changed = true
            }
            let matches = matchingDanmakuFiles(for: file, candidates: danmakuFiles)
            if !matches.isEmpty {
                _ = try? await associateDanmaku(matches, with: file, replaceExisting: false)
            }
        }
        if changed { LibraryStore.save(items) }
    }

    /// 处理文件选择结果，用安全作用域书签持久化访问权（FR-IMP-001）
    private func handleImport(_ result: Result<[URL], Error>) async {
        isProcessingImport = true
        defer { isProcessingImport = false }
        do {
            let urls = try result.get()
            let videoURLs = urls.filter(isVideoFile)
            let selectedDanmakuURLs = urls.filter(isDanmakuFile)
            guard !videoURLs.isEmpty else {
                importError = "请选择至少一个视频；单独的弹幕文件可在播放页导入"
                return
            }

            var importedItems: [LibraryItem] = []
            for url in videoURLs {
                guard let item = LibraryItem(url: url) else {
                    importError = "无法为 \(url.lastPathComponent) 创建访问书签"
                    continue
                }
                importedItems.append(item)
            }
            guard !importedItems.isEmpty else { return }
            if selectedDanmakuURLs.isEmpty {
                let grouped = Dictionary(grouping: importedItems) { $0.title }
                let prepared = grouped.flatMap { title, values -> [LibraryItem] in
                    let sorted = values.sorted(by: LibraryItem.collectionOrder)
                    guard sorted.count > 1 else { return sorted }
                    let collectionID = "local-selection:\(UUID().uuidString):\(title)"
                    return sorted.enumerated().map { offset, item in
                        item.assigningCollection(id: collectionID, title: title, index: offset + 1)
                    }
                }
                pendingLocalImport = MediaImportDraft(
                    title: importedItems.count == 1 ? importedItems[0].libraryTitle : "本地视频",
                    items: prepared,
                    prefersMergedCollection: grouped.count == 1 && importedItems.count > 1
                )
                return
            }
            for item in importedItems {
                if !items.contains(where: { $0.id == item.id }) { items.append(item) }
            }
            LibraryStore.save(items)

            var associatedCount = 0
            for videoURL in videoURLs {
                var candidates = videoURLs.count == 1
                    ? selectedDanmakuURLs
                    : matchingDanmakuFiles(for: videoURL, candidates: selectedDanmakuURLs)
                candidates.append(contentsOf: siblingDanmakuFiles(for: videoURL))
                candidates = uniqueURLs(candidates)
                guard !candidates.isEmpty else { continue }
                if try await associateDanmaku(candidates, with: videoURL, replaceExisting: true) {
                    associatedCount += 1
                }
            }

            if !selectedDanmakuURLs.isEmpty && associatedCount == 0 {
                importError = "未找到能与所选视频关联的弹幕文件，请在播放页手动导入"
            }
        } catch {
            importError = error.localizedDescription
        }
    }

    /// 判断 URL 是否为播放器当前支持导入的视频文件。
    private func isVideoFile(_ url: URL) -> Bool {
        let supported: Set<String> = ["mp4", "mkv", "mov", "m4v", "ts", "avi", "flv", "webm"]
        return supported.contains(url.pathExtension.lowercased())
    }

    /// 判断 URL 是否为本地弹幕解析器支持的文件。
    private func isDanmakuFile(_ url: URL) -> Bool {
        ["xml", "json", "ass"].contains(url.pathExtension.lowercased())
    }

    /// 从候选中找出与视频基础文件名一致或带语言后缀的弹幕文件。
    private func matchingDanmakuFiles(for videoURL: URL, candidates: [URL]) -> [URL] {
        let videoStem = videoURL.deletingPathExtension().lastPathComponent.lowercased()
        return candidates.filter { candidate in
            let stem = candidate.deletingPathExtension().lastPathComponent.lowercased()
            return stem == videoStem || stem.hasPrefix("\(videoStem).")
        }
    }

    /// 尝试扫描视频所在目录中的同名弹幕文件；没有目录权限时安全返回空数组。
    private func siblingDanmakuFiles(for videoURL: URL) -> [URL] {
        let hasAccess = videoURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { videoURL.stopAccessingSecurityScopedResource() }
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: videoURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return matchingDanmakuFiles(for: videoURL, candidates: files.filter(isDanmakuFile))
    }

    /// 去除文件选择结果与目录扫描产生的重复 URL。
    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<URL> = []
        return urls.filter { seen.insert($0.standardizedFileURL).inserted }
    }

    /// 解析并合并一个或多个弹幕文件，再按视频指纹持久化关联。
    private func associateDanmaku(
        _ danmakuURLs: [URL],
        with videoURL: URL,
        replaceExisting: Bool
    ) async throws -> Bool {
        let hasVideoAccess = videoURL.startAccessingSecurityScopedResource()
        defer {
            if hasVideoAccess { videoURL.stopAccessingSecurityScopedResource() }
        }
        let fingerprint = try await Task.detached(priority: .utility) {
            try FingerprintCalculator.compute(fileURL: videoURL, duration: 0)
        }.value
        if !replaceExisting,
           try await LocalDanmakuStore.shared.load(for: fingerprint) != nil {
            return false
        }

        var combinedItems: [DanmakuItem] = []
        var fileNames: [String] = []
        for (fileIndex, danmakuURL) in danmakuURLs.enumerated() {
            let hasDanmakuAccess = danmakuURL.startAccessingSecurityScopedResource()
            let data: Data
            do {
                data = try Data(contentsOf: danmakuURL)
            } catch {
                if hasDanmakuAccess { danmakuURL.stopAccessingSecurityScopedResource() }
                throw error
            }
            if hasDanmakuAccess { danmakuURL.stopAccessingSecurityScopedResource() }
            let parsedItems = try await Task.detached(priority: .utility) {
                try LocalDanmakuParser.parse(data: data, fileName: danmakuURL.lastPathComponent)
            }.value
            combinedItems.append(contentsOf: parsedItems.map { item in
                DanmakuItem(
                    id: "local:file\(fileIndex):\(item.id)",
                    time: item.time,
                    mode: item.mode,
                    fontSize: item.fontSize,
                    color: item.color,
                    content: item.content,
                    source: .local,
                    senderHash: item.senderHash,
                    createdAt: item.createdAt,
                    weight: item.weight,
                    dupCount: item.dupCount
                )
            })
            fileNames.append(danmakuURL.lastPathComponent)
        }
        guard !combinedItems.isEmpty else { throw LocalDanmakuError.noDanmaku }
        let displayName = fileNames.count == 1 ? fileNames[0] : "\(fileNames.count) 个本地弹幕文件"
        try await LocalDanmakuStore.shared.save(
            items: combinedItems.sorted { $0.time < $1.time },
            fileName: displayName,
            for: fingerprint
        )
        return true
    }
}

private extension View {
    /// 仅在触屏平台使用系统搜索栏，避免 tvOS 启动时自动弹出屏幕键盘。
    /// - Parameters:
    ///   - text: 当前搜索关键词。
    ///   - isPresented: 搜索栏是否已展开。
    /// - Returns: 应用平台搜索行为后的视图。
    @ViewBuilder
    func kanataLibrarySearch(text: Binding<String>, isPresented: Binding<Bool>) -> some View {
        #if os(tvOS)
        self
        #else
        searchable(text: text, isPresented: isPresented, prompt: "搜索标题或集数")
        #endif
    }
}

#if os(tvOS)
/// Apple TV 媒体库搜索面板，仅在用户主动点击搜索后显示键盘。
private struct TVLibrarySearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var searchText: String

    var body: some View {
        NavigationStack {
            Form {
                TextField("标题或集数", text: $searchText)
            }
            .navigationTitle("搜索媒体库")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .kanataToolbarTextButton()
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("清除") {
                        searchText = ""
                        dismiss()
                    }
                    .kanataToolbarTextButton()
                }
            }
        }
    }
}
#endif

/// 媒体卡片的异步视频缩略图；优先使用服务器海报，本地视频截取第一秒。
private struct MediaArtworkView: View {
    let item: LibraryItem
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.16, blue: 0.32), Color(red: 0.22, green: 0.08, blue: 0.34)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: item.remoteURLString == nil ? "play.rectangle.fill" : "network")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.white.opacity(0.82))
            }
        }
        .clipped()
        .task(id: item.id) { await loadThumbnail() }
    }

    /// 下载带认证头的服务器海报，或从本地视频第一秒生成缩略图。
    private func loadThumbnail() async {
        if let rawURL = item.artworkURLString, let url = URL(string: rawURL) {
            var request = URLRequest(url: url)
            item.requestHeaders().forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            request.cachePolicy = .returnCacheDataElseLoad
            if let (data, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode),
               let image = UIImage(data: data) {
                thumbnail = image
            }
            return
        }
        guard item.remoteURLString == nil, let url = item.resolveURL() else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        if let (image, _) = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)) {
            thumbnail = UIImage(cgImage: image)
        }
    }
}

/// 媒体库条目，保存本地书签或网络地址，认证信息只引用 Keychain。
struct LibraryItem: Identifiable, Codable, Hashable {
    let id: String
    let displayName: String
    /// 安全作用域书签，App 重启后仍可访问原文件
    let bookmark: Data?
    /// 可直接交给 AVPlayer 的 HTTP(S) 视频或 HLS 地址。
    let remoteURLString: String?
    /// 媒体来源显示名称，例如 WebDAV 或 Jellyfin。
    let sourceName: String?
    /// 媒体服务器提供的海报或剧集缩略图地址。
    let artworkURLString: String?
    /// 存储在 Keychain 的请求头账号名，媒体库本身不保存密码或令牌。
    let credentialAccount: String?
    /// 视频所属的持久化媒体源，用于从 Keychain 动态生成播放请求头。
    var sourceProfileID: String?
    /// 媒体服务器上的原始条目 ID，用于运行时生成转码地址，不保存访问令牌。
    let serverItemID: String?
    /// Jellyfin/Emby 当前媒体版本 ID，用于生成准确的 HLS 转码会话。
    let serverMediaSourceID: String?
    /// 同一目录、季度或剧集共享的播放合集标识。
    var collectionID: String?
    var collectionTitle: String?
    var collectionIndex: Int?
    /// 最近添加栏目使用的时间；旧版媒体库缺少该字段时保持 nil。
    let addedAt: Date?
    var title: String
    var season: Int?
    var episode: Int?

    /// 播放进度存储使用的稳定媒体标识。
    var mediaKey: String? { resolveURL()?.absoluteString }

    /// 从文件选择器返回的地址创建条目，创建书签失败时返回 nil
    init?(
        url: URL,
        collectionID: String? = nil,
        collectionTitle: String? = nil,
        collectionIndex: Int? = nil,
        season: Int? = nil,
        episode: Int? = nil
    ) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? url.bookmarkData(options: .minimalBookmark) else { return nil }
        let parent = url.deletingLastPathComponent()
        let parsed = TitleParser.parse(
            url.lastPathComponent,
            folderNames: [parent.lastPathComponent, parent.deletingLastPathComponent().lastPathComponent]
        )
        self.id = "local:\(url.standardizedFileURL.absoluteString)"
        self.displayName = url.lastPathComponent
        self.bookmark = bookmark
        self.remoteURLString = nil
        self.sourceName = nil
        self.artworkURLString = nil
        self.credentialAccount = nil
        self.sourceProfileID = nil
        self.serverItemID = nil
        self.serverMediaSourceID = nil
        self.collectionID = collectionID
        self.collectionTitle = collectionTitle
        self.collectionIndex = collectionIndex
        self.addedAt = Date()
        self.title = parsed.title
        self.season = season ?? parsed.season
        self.episode = episode ?? parsed.episode
    }

    /// 创建一个网络视频条目。
    /// - Parameters:
    ///   - remoteURL: HTTP(S) 视频、HLS 或 NAS 直链。
    ///   - name: 用户提供的显示名称，空值时从 URL 推断。
    ///   - stableID: 媒体服务器逻辑条目 ID；同一底层文件存在多个别名时用于隔离条目。
    init(
        remoteURL: URL,
        name: String,
        stableID: String? = nil,
        sourceName: String? = nil,
        artworkURL: URL? = nil,
        credentialAccount: String? = nil,
        sourceProfileID: String? = nil,
        serverItemID: String? = nil,
        serverMediaSourceID: String? = nil,
        collectionID: String? = nil,
        collectionTitle: String? = nil,
        collectionIndex: Int? = nil,
        season: Int? = nil,
        episode: Int? = nil
    ) {
        let inferredName = remoteURL.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? ""
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (!inferredName.isEmpty ? inferredName : (remoteURL.host ?? "网络视频"))
            : name.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = TitleParser.parse(displayName, folderNames: collectionTitle.map { [$0] } ?? [])
        if let stableID {
            let serverIdentity = [
                sourceName ?? "network",
                remoteURL.host ?? "unknown-host",
                remoteURL.port.map(String.init) ?? "default-port",
            ].joined(separator: ":")
            self.id = "remote:\(serverIdentity):\(stableID)"
        } else {
            self.id = "remote:\(remoteURL.absoluteString)"
        }
        self.displayName = displayName
        self.bookmark = nil
        self.remoteURLString = remoteURL.absoluteString
        self.sourceName = sourceName
        self.artworkURLString = artworkURL?.absoluteString
        self.credentialAccount = credentialAccount
        self.sourceProfileID = sourceProfileID
        self.serverItemID = serverItemID
        self.serverMediaSourceID = serverMediaSourceID
        self.collectionID = collectionID
        self.collectionTitle = collectionTitle
        self.collectionIndex = collectionIndex
        self.addedAt = Date()
        self.title = parsed.title
        self.season = season ?? parsed.season
        self.episode = episode ?? parsed.episode
    }

    /// 列表副标题：展示解析出的剧名与季集号
    var subtitle: String {
        var parts = [title.isEmpty ? "未识别" : title]
        if let season, let episode {
            parts.append(String(format: "S%02dE%02d", season, episode))
        }
        if let remoteURLString, let host = URL(string: remoteURLString)?.host {
            parts.append(host)
        }
        if let sourceName { parts.append(sourceName) }
        if let collectionTitle, let collectionIndex {
            parts.append("\(collectionTitle) · 第 \(collectionIndex) 集")
        }
        return parts.joined(separator: " · ")
    }

    /// 首页和历史记录使用的作品标题；合集条目不再直接展示冗长文件名。
    var libraryTitle: String {
        let collection = collectionTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !collection.isEmpty { return collection }
        let parsedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return parsedTitle.isEmpty ? displayName : parsedTitle
    }

    /// 返回用户可读的季集标识，无法识别时返回 nil。
    var episodeLabel: String? {
        guard let value = episode ?? collectionIndex else { return nil }
        if let season, season > 1 { return "第 \(season) 季 · 第 \(value) 集" }
        return "第 \(value) 集"
    }

    /// 历史记录副标题，明确显示当前集数与原始文件名。
    var historySubtitle: String {
        var values: [String] = []
        if let episodeLabel { values.append(episodeLabel) }
        if displayName.caseInsensitiveCompare(libraryTitle) != .orderedSame {
            values.append(displayName)
        }
        if let sourceName { values.append(sourceName) }
        return values.isEmpty ? subtitle : values.joined(separator: " · ")
    }

    /// 复制条目并替换合集归属，供导入预览的“合并为一个合集”使用。
    /// - Parameters:
    ///   - id: 新合集稳定标识。
    ///   - title: 新合集显示标题。
    ///   - index: 条目在新合集中的顺序。
    /// - Returns: 保留播放地址与认证信息的新条目。
    func assigningCollection(id: String?, title: String?, index: Int?) -> LibraryItem {
        var value = self
        value.collectionID = id
        value.collectionTitle = title
        value.collectionIndex = index
        return value
    }

    /// 以新版文件命名规则刷新可推断的剧名与季集号，同时保留媒体服务器提供的可靠元数据。
    /// - Returns: 适用于旧媒体库记录的向前兼容条目。
    func refreshingParsedMetadata() -> LibraryItem {
        let parsed = TitleParser.parse(displayName, folderNames: collectionTitle.map { [$0] } ?? [])
        var value = self
        if !parsed.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            value.title = parsed.title
        }
        if let episode = parsed.episode {
            value.episode = episode
            value.season = parsed.season ?? value.season
        } else if value.episode == parsed.year || containsTechnicalEpisode(value.episode) {
            value.episode = nil
            if value.season == 1 { value.season = parsed.season }
        } else if value.season == nil {
            value.season = parsed.season
        }
        return value
    }

    /// 判断旧解析结果是否来自 `[1080]`、`1080p` 等清晰度标签。
    /// - Parameter episode: 旧媒体库保存的候选集号。
    /// - Returns: 文件名明确把该数字作为技术标签时返回 true。
    private func containsTechnicalEpisode(_ episode: Int?) -> Bool {
        guard let episode,
              [480, 720, 1080, 1440, 2160, 4320].contains(episode) else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: String(episode))
        return displayName.range(
            of: "(?i)(?:\\[\\s*\(escaped)\\s*\\]|\(escaped)p)",
            options: .regularExpression
        ) != nil
    }

    /// 解析书签取回文件地址，文件已失效时返回 nil
    func resolveURL() -> URL? {
        if let remoteURLString {
            guard var components = URLComponents(string: remoteURLString) else { return nil }
            if let sourceProfileID,
               let profile = MediaSourceProfileStore.profile(id: sourceProfileID),
               profile.kind == .synology,
               let sid = MediaSourceProfileStore.secret(for: profile)?.token,
               !sid.isEmpty {
                var queryItems = components.queryItems ?? []
                queryItems.removeAll { $0.name == "_sid" }
                queryItems.append(URLQueryItem(name: "_sid", value: sid))
                components.queryItems = queryItems
            }
            return components.url
        }
        guard let bookmark else { return nil }
        var isStale = false
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    /// 返回媒体服务器的兼容 HLS 地址，用于原始文件播放失败后的自动重试。
    /// - Returns: 不支持服务端转码或缺少凭证时返回 nil。
    func compatibilityPlaybackURL() -> URL? {
        guard let sourceProfileID,
              let profile = MediaSourceProfileStore.profile(id: sourceProfileID),
              let server = profile.serverURL else {
            return nil
        }
        switch profile.kind {
        case .jellyfin, .emby:
            guard let itemID = serverItemID ?? mediaBrowserItemIDFromStoredURL(),
                  let token = MediaSourceProfileStore.secret(for: profile)?.token,
                  !token.isEmpty else { return nil }
            return mediaBrowserHLSURL(
                server: server,
                itemID: itemID,
                mediaSourceID: serverMediaSourceID ?? itemID,
                token: token
            )
        case .plex:
            guard let itemID = plexItemID,
                  let token = MediaSourceProfileStore.secret(for: profile)?.token,
                  !token.isEmpty else { return nil }
            return plexHLSURL(server: server, itemID: itemID, token: token)
        case .webDAV, .synology:
            return nil
        }
    }

    /// 从旧版 MediaBrowser 静态流地址恢复条目 ID。
    /// - Returns: `/Videos/{id}/stream` 中的 id，无法识别时返回 nil。
    private func mediaBrowserItemIDFromStoredURL() -> String? {
        guard let remoteURLString, let url = URL(string: remoteURLString) else { return nil }
        let parts = url.pathComponents
        guard let videosIndex = parts.firstIndex(where: { $0.caseInsensitiveCompare("Videos") == .orderedSame }),
              parts.indices.contains(videosIndex + 1) else { return nil }
        return parts[videosIndex + 1]
    }

    /// 生成 Jellyfin/Emby 的 HLS 兼容流地址，让服务器处理 MKV、10-bit 和音频封装差异。
    /// - Parameters:
    ///   - server: 媒体服务器根地址。
    ///   - itemID: 服务端媒体条目 ID。
    ///   - mediaSourceID: 服务端媒体版本 ID。
    ///   - token: 仅在运行时从 Keychain 读取的访问令牌。
    /// - Returns: 可交给 AVPlayer 的 HLS 地址。
    private func mediaBrowserHLSURL(
        server: URL,
        itemID: String,
        mediaSourceID: String,
        token: String
    ) -> URL? {
        var components = URLComponents(
            url: server.appendingPathComponent("Videos/\(itemID)/master.m3u8"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: token),
            URLQueryItem(name: "MediaSourceId", value: mediaSourceID),
            URLQueryItem(name: "DeviceId", value: "kanata-apple"),
            URLQueryItem(name: "PlaySessionId", value: UUID().uuidString),
            URLQueryItem(name: "VideoCodec", value: "h264"),
            URLQueryItem(name: "AudioCodec", value: "aac"),
            URLQueryItem(name: "VideoBitrate", value: "60000000"),
            URLQueryItem(name: "AudioBitrate", value: "384000"),
            URLQueryItem(name: "TranscodingMaxAudioChannels", value: "2"),
            URLQueryItem(name: "AllowVideoStreamCopy", value: "false"),
            URLQueryItem(name: "AllowAudioStreamCopy", value: "false"),
            URLQueryItem(name: "SegmentContainer", value: "ts"),
            URLQueryItem(name: "MinSegments", value: "1"),
            URLQueryItem(name: "BreakOnNonKeyFrames", value: "true"),
        ]
        return components?.url
    }

    /// 返回新旧媒体库记录中的 Plex ratingKey。
    private var plexItemID: String? {
        let raw = serverItemID ?? id.components(separatedBy: "plex-video:").last
        guard let raw, !raw.isEmpty else { return nil }
        return raw.replacingOccurrences(of: "plex-video:", with: "")
    }

    /// 生成 Plex Universal Transcoder 的 HLS 地址，令牌仅存在于本次内存 URL。
    /// - Parameters:
    ///   - server: Plex Media Server 根地址。
    ///   - itemID: Plex ratingKey。
    ///   - token: 运行时从 Keychain 读取的 Plex Token。
    /// - Returns: Plex 可直接播放或按需转码的 HLS 地址。
    private func plexHLSURL(server: URL, itemID: String, token: String) -> URL? {
        var components = URLComponents(
            url: server.appendingPathComponent("video/:/transcode/universal/start.m3u8"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "path", value: "/library/metadata/\(itemID)"),
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "directPlay", value: "1"),
            URLQueryItem(name: "directStream", value: "1"),
            URLQueryItem(name: "fastSeek", value: "1"),
            URLQueryItem(name: "maxVideoBitrate", value: "40000"),
            URLQueryItem(name: "videoQuality", value: "100"),
            URLQueryItem(name: "session", value: UUID().uuidString),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: "com.kanata.app"),
            URLQueryItem(name: "X-Plex-Product", value: "Kanata"),
            URLQueryItem(name: "X-Plex-Token", value: token),
        ]
        return components?.url
    }

    /// 从 Keychain 读取网络媒体播放所需的请求头。
    /// - Returns: 没有凭证或凭证失效时返回空字典。
    func requestHeaders() -> [String: String] {
        if let sourceProfileID,
           let profile = MediaSourceProfileStore.profile(id: sourceProfileID) {
            return MediaSourceProfileStore.playbackHeaders(for: profile)
        }
        guard let credentialAccount,
              let data = KeychainStore.data(account: credentialAccount),
              let credential = try? JSONDecoder().decode(MediaRequestCredential.self, from: data) else {
            return [:]
        }
        return credential.headers
    }

    /// 按显式合集序号和自然文件名排序播放队列。
    /// - Parameters:
    ///   - left: 左侧媒体条目。
    ///   - right: 右侧媒体条目。
    /// - Returns: 左侧应先播放时返回 true。
    static func collectionOrder(_ left: LibraryItem, _ right: LibraryItem) -> Bool {
        if let leftIndex = left.collectionIndex,
           let rightIndex = right.collectionIndex,
           leftIndex != rightIndex {
            return leftIndex < rightIndex
        }
        return left.displayName.localizedStandardCompare(right.displayName) == .orderedAscending
    }

    /// 合并多个目录时按季度、原目录、真实集数和自然文件名稳定排序。
    /// - Parameters:
    ///   - left: 左侧媒体条目。
    ///   - right: 右侧媒体条目。
    /// - Returns: 左侧应排在前面时返回 true。
    static func mergedCollectionOrder(_ left: LibraryItem, _ right: LibraryItem) -> Bool {
        let leftSeason = left.season ?? TitleParser.parse(left.collectionTitle ?? "").season
        let rightSeason = right.season ?? TitleParser.parse(right.collectionTitle ?? "").season
        if leftSeason != rightSeason {
            if let leftSeason, let rightSeason { return leftSeason < rightSeason }
            return leftSeason != nil
        }
        let leftGroup = left.collectionTitle ?? ""
        let rightGroup = right.collectionTitle ?? ""
        let groupComparison = leftGroup.localizedStandardCompare(rightGroup)
        if groupComparison != .orderedSame { return groupComparison == .orderedAscending }
        if left.episode != right.episode {
            if let leftEpisode = left.episode, let rightEpisode = right.episode {
                return leftEpisode < rightEpisode
            }
            return left.episode != nil
        }
        return collectionOrder(left, right)
    }

    /// 保留各目录为独立合集时，先稳定排列合集，再排列合集内剧集。
    /// - Parameters:
    ///   - left: 左侧媒体条目。
    ///   - right: 右侧媒体条目。
    /// - Returns: 左侧应排在前面时返回 true。
    static func groupedCollectionOrder(_ left: LibraryItem, _ right: LibraryItem) -> Bool {
        let leftTitle = left.collectionTitle ?? ""
        let rightTitle = right.collectionTitle ?? ""
        let titleComparison = leftTitle.localizedStandardCompare(rightTitle)
        if titleComparison != .orderedSame { return titleComparison == .orderedAscending }
        let leftID = left.collectionID ?? left.id
        let rightID = right.collectionID ?? right.id
        if leftID != rightID { return leftID < rightID }
        return collectionOrder(left, right)
    }
}

/// 首页用于展示同一目录、剧集或季度的聚合模型。
private struct MediaCollection: Identifiable {
    let id: String
    let title: String
    let items: [LibraryItem]
    let nextItem: LibraryItem
}

/// 合集详情与剧集编排页面，播放前让用户确认顺序和忽略项。
private struct CollectionDetailView: View {
    let collection: MediaCollection
    let onPlay: ([LibraryItem], LibraryItem) -> Void
    let onRemove: (LibraryItem) -> Void
    let onRename: (String, String) -> Void
    let onChanged: () -> Void
    @State private var orderedItems: [LibraryItem]
    @State private var ignoredIDs: Set<String>
    @State private var collectionTitle: String
    @State private var pendingTitle: String
    @State private var isRenaming = false

    /// 使用已保存顺序初始化合集详情。
    /// - Parameters:
    ///   - collection: 当前合集。
    ///   - onPlay: 播放队列回调。
    ///   - onRemove: 从媒体库移除单集的回调。
    ///   - onRename: 合集重命名回调。
    ///   - onChanged: 编排变化通知。
    init(
        collection: MediaCollection,
        onPlay: @escaping ([LibraryItem], LibraryItem) -> Void,
        onRemove: @escaping (LibraryItem) -> Void,
        onRename: @escaping (String, String) -> Void,
        onChanged: @escaping () -> Void
    ) {
        self.collection = collection
        self.onPlay = onPlay
        self.onRemove = onRemove
        self.onRename = onRename
        self.onChanged = onChanged
        let values = CollectionLayoutStore.ordered(
            collection.items,
            collectionID: collection.id,
            includesIgnored: true
        )
        _orderedItems = State(initialValue: values)
        _ignoredIDs = State(initialValue: CollectionLayoutStore.layout(for: collection.id).ignoredItemIDs)
        _collectionTitle = State(initialValue: collection.title)
        _pendingTitle = State(initialValue: collection.title)
    }

    /// 当前自动连播会使用的剧集队列。
    private var activeItems: [LibraryItem] {
        orderedItems.filter { !ignoredIDs.contains($0.id) }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        Image(systemName: "rectangle.stack.fill")
                            .font(.title)
                            .foregroundStyle(KanataTheme.accent)
                            .frame(width: 54, height: 54)
                            .background(KanataTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(collectionTitle)
                                .font(.title3.bold())
                            Text("\(activeItems.count) 集参与连播 · \(ignoredIDs.count) 集已忽略")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        guard let item = activeItems.first(where: { $0.id == collection.nextItem.id }) ?? activeItems.first else { return }
                        onPlay(activeItems, item)
                    } label: {
                        Label("继续播放", systemImage: "play.fill")
                    }
                    .buttonStyle(KanataPrimaryButtonStyle())
                    .disabled(activeItems.isEmpty)
                }
                .padding(.vertical, 8)
            }

            Section("剧集顺序") {
                ForEach(Array(orderedItems.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 12) {
                        Button {
                            let queue = ignoredIDs.contains(item.id) ? [item] : activeItems
                            onPlay(queue, item)
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.episodeLabel ?? item.displayName)
                                        .foregroundStyle(ignoredIDs.contains(item.id) ? .secondary : .primary)
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
                                Spacer()
                                if ignoredIDs.contains(item.id) {
                                    Text("已忽略")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(KanataTheme.warning)
                                }
                            }
                            .contentShape(Rectangle())
                            .frame(maxWidth: .infinity, minHeight: collectionEpisodeRowHeight)
                        }
                        .kanataTVFocus(cornerRadius: 14)
                        Menu {
                            Button("上移", systemImage: "arrow.up") { move(itemID: item.id, delta: -1) }
                                .disabled(index == 0)
                            Button("下移", systemImage: "arrow.down") { move(itemID: item.id, delta: 1) }
                                .disabled(index == orderedItems.count - 1)
                            Button(
                                ignoredIDs.contains(item.id) ? "恢复连播" : "从连播忽略",
                                systemImage: ignoredIDs.contains(item.id) ? "eye" : "eye.slash"
                            ) {
                                toggleIgnored(item)
                            }
                            Button("从媒体库移除", systemImage: "trash", role: .destructive) {
                                remove(item)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .frame(width: 54, height: 54)
                        }
                        .kanataTVFocus(cornerRadius: 27)
                    }
                }
                .onMove(perform: move)
            }
        }
        .navigationTitle(collectionNavigationTitle)
        .kanataInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    pendingTitle = collectionTitle
                    isRenaming = true
                } label: {
                    Label("重命名", systemImage: "pencil")
                }
            }
            #if !os(tvOS)
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            #endif
        }
        .alert("重命名合集", isPresented: $isRenaming) {
            TextField("合集名称", text: $pendingTitle)
            Button("取消", role: .cancel) {}
            Button("保存") { renameCollection() }
        } message: {
            Text("只修改媒体库中的显示名称，不会更改服务器文件夹或文件。")
        }
    }

    /// 返回 tvOS 避免与详情正文重复的导航标题。
    private var collectionNavigationTitle: String {
        #if os(tvOS)
        "合集详情"
        #else
        collectionTitle
        #endif
    }

    /// 返回适合电视观看距离的剧集行高。
    private var collectionEpisodeRowHeight: CGFloat {
        #if os(tvOS)
        78
        #else
        44
        #endif
    }

    /// 响应系统编辑模式拖动并保存新顺序。
    /// - Parameters:
    ///   - source: 被移动条目的索引集合。
    ///   - destination: 目标索引。
    private func move(from source: IndexSet, to destination: Int) {
        orderedItems.move(fromOffsets: source, toOffset: destination)
        persistOrder()
    }

    /// 通过菜单把指定剧集上移或下移一位。
    /// - Parameters:
    ///   - itemID: 剧集 ID。
    ///   - delta: -1 上移，1 下移。
    private func move(itemID: String, delta: Int) {
        guard let index = orderedItems.firstIndex(where: { $0.id == itemID }) else { return }
        let target = min(max(index + delta, 0), orderedItems.count - 1)
        guard target != index else { return }
        let item = orderedItems.remove(at: index)
        orderedItems.insert(item, at: target)
        persistOrder()
    }

    /// 切换一集是否参与自动连播。
    /// - Parameter item: 用户操作的剧集。
    private func toggleIgnored(_ item: LibraryItem) {
        CollectionLayoutStore.toggleIgnored(itemID: item.id, collectionID: collection.id)
        ignoredIDs = CollectionLayoutStore.layout(for: collection.id).ignoredItemIDs
        onChanged()
    }

    /// 从媒体库移除一集并保持剩余顺序。
    /// - Parameter item: 要移除的条目。
    private func remove(_ item: LibraryItem) {
        orderedItems.removeAll { $0.id == item.id }
        ignoredIDs.remove(item.id)
        CollectionLayoutStore.toggleIgnoredIfNeeded(
            itemID: item.id,
            collectionID: collection.id,
            shouldIgnore: false
        )
        persistOrder()
        onRemove(item)
    }

    /// 持久化当前剧集顺序并通知首页刷新。
    private func persistOrder() {
        CollectionLayoutStore.saveOrder(orderedItems, collectionID: collection.id)
        onChanged()
    }

    /// 校验并保存合集的新显示名称。
    private func renameCollection() {
        let value = pendingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        collectionTitle = value
        onRename(collection.id, value)
    }
}

/// 首页媒体源频道的轻量连通性状态。
private enum MediaSourceHealth: Equatable {
    case checking
    case online
    case offline

    var title: String {
        switch self {
        case .checking: "检测中"
        case .online: "在线"
        case .offline: "不可用"
        }
    }
}

/// 播放器一次打开的单视频或合集队列。
struct PlaybackQueue: Identifiable {
    let items: [LibraryItem]
    let initialItemID: String

    var id: String { initialItemID }
}

/// 保存在 Keychain 中的媒体请求头，不参与媒体库 JSON 持久化。
struct MediaRequestCredential: Codable {
    let headers: [String: String]
}

/// 媒体库的本地持久化。M0 用 UserDefaults，M1 换成 SQLite（docs/02 §5）。
enum LibraryStore {
    private static let key = "library.items"
    private static let parserVersionKey = "library.title-parser-version"
    private static let parserVersion = 2

    /// 读取媒体库，并在命名规则升级后一次性刷新旧条目的可推断元数据。
    /// - Returns: 当前媒体库条目。
    static func load() -> [LibraryItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([LibraryItem].self, from: data) else {
            return []
        }
        guard UserDefaults.standard.integer(forKey: parserVersionKey) < parserVersion else {
            return items
        }
        let refreshed = items.map { $0.refreshingParsedMetadata() }
        save(refreshed, schedulesCloudPush: false)
        UserDefaults.standard.set(parserVersion, forKey: parserVersionKey)
        return refreshed
    }

    /// 持久化全部媒体库条目。
    /// - Parameters:
    ///   - items: 当前媒体库快照。
    ///   - schedulesCloudPush: 是否安排 iCloud 上传。
    static func save(_ items: [LibraryItem], schedulesCloudPush: Bool = true) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
        if schedulesCloudPush {
            Task { @MainActor in CloudSyncStore.shared.noteLocalChange() }
        }
    }

    /// 导出可跨设备访问的网络媒体库索引，本地安全书签不会进入 iCloud。
    /// - Returns: 网络媒体条目的 JSON 数据。
    static func exportCloudData() -> Data? {
        try? JSONEncoder().encode(load().filter { $0.remoteURLString != nil })
    }

    /// 用云端网络媒体库替换本机网络索引，同时保留本机文件并重映射媒体源 ID。
    /// - Parameters:
    ///   - data: 云端网络媒体条目 JSON。
    ///   - profileIDMap: 云端媒体源 ID 到本机媒体源 ID 的映射。
    static func importCloudData(_ data: Data?, profileIDMap: [String: String]) {
        guard let data,
              let cloudItems = try? JSONDecoder().decode([LibraryItem].self, from: data) else { return }
        let localItems = load().filter { $0.remoteURLString == nil }
        let remoteItems = cloudItems.map { item -> LibraryItem in
            var value = item
            if let profileID = item.sourceProfileID {
                value.sourceProfileID = profileIDMap[profileID] ?? profileID
            }
            return value
        }
        save(localItems + remoteItems, schedulesCloudPush: false)
    }
}

/// 媒体收藏的轻量本地存储，只保存条目 ID。
enum LibraryFavoriteStore {
    private static let key = "library.favorite-ids.v1"

    /// 读取全部收藏条目 ID。
    /// - Returns: 尚无收藏时返回空集合。
    static func load() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    /// 保存全部收藏条目 ID。
    /// - Parameter ids: 当前收藏集合。
    static func save(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids).sorted(), forKey: key)
        Task { @MainActor in CloudSyncStore.shared.noteLocalChange() }
    }

    /// 从 iCloud 快照替换收藏集合，不触发反向上传。
    /// - Parameter ids: 云端收藏条目 ID。
    static func applyCloudValue(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids).sorted(), forKey: key)
    }
}
