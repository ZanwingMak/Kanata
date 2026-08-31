import AVFoundation
import KanataCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// 媒体库首页。M0 只支持本地文件导入，NAS 与媒体服务器在 M1 接入（FR-IMP-003 起）。
struct LibraryView: View {
    @Environment(AppSettings.self) private var settings
    @State private var isImporting = false
    @State private var isShowingSettings = false
    @State private var items: [LibraryItem] = LibraryStore.load()
    @State private var playing: LibraryItem?
    @State private var importError: String?
    @State private var isProcessingImport = false
    @State private var isAddingNetworkVideo = false
    @State private var searchText = ""
    @State private var isSearching = false

    #if os(tvOS)
    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 480), spacing: 36)]
    #else
    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 320), spacing: 16)]
    #endif

    /// 按标题与解析信息过滤媒体库。
    private var filteredItems: [LibraryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.subtitle.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color.black, Color(red: 0.035, green: 0.055, blue: 0.11)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                if items.isEmpty {
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
                            .buttonStyle(.borderedProminent)
                            .disabled(isProcessingImport)
                        #endif
                        Button("添加网络视频") { isAddingNetworkVideo = true }
                            .buttonStyle(.bordered)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("全部视频")
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
                        .padding(.horizontal, 18)
                        .padding(.bottom, 32)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .navigationTitle("媒体库")
            .kanataLibrarySearch(text: $searchText, isPresented: $isSearching)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { isShowingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
                #if os(tvOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isSearching = true } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("搜索媒体库")
                }
                #endif
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
                                isAddingNetworkVideo = true
                            } label: {
                                Label("添加网络视频", systemImage: "network")
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("导入视频和弹幕")
                    }
                }
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
            .fullScreenCover(item: $playing) { item in
                if let url = item.resolveURL() {
                    PlayerScreen(url: url)
                } else {
                    ContentUnavailableView(
                        "无法访问该文件",
                        systemImage: "exclamationmark.triangle",
                        description: Text("文件可能已被移动或删除，请重新导入")
                    )
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsView()
            }
            #if os(tvOS)
            .sheet(isPresented: $isSearching) {
                TVLibrarySearchSheet(searchText: $searchText)
            }
            #endif
            .sheet(isPresented: $isAddingNetworkVideo) {
                NetworkVideoSheet { item in
                    if !items.contains(where: { $0.id == item.id }) {
                        items.append(item)
                        LibraryStore.save(items)
                    }
                    playing = item
                }
            }
            .task { await scanDocuments() }
        }
        .tint(.cyan)
    }

    /// 创建一个带视频缩略图、来源与删除菜单的媒体卡片。
    /// - Parameter item: 媒体库条目。
    /// - Returns: 可点击播放的卡片视图。
    private func mediaCard(_ item: LibraryItem) -> some View {
        Button {
            playing = item
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
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(10)
                    }
                Text(item.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("从媒体库移除", systemImage: "trash", role: .destructive) {
                removeItem(item)
            }
        }
        .accessibilityLabel("播放 \(item.displayName)")
    }

    /// 从媒体库索引移除条目，不删除原始视频文件。
    /// - Parameter item: 待移除的条目。
    private func removeItem(_ item: LibraryItem) {
        items.removeAll { $0.id == item.id }
        LibraryStore.save(items)
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

            for url in videoURLs {
                guard let item = LibraryItem(url: url) else {
                    importError = "无法为 \(url.lastPathComponent) 创建访问书签"
                    continue
                }
                if !items.contains(where: { $0.id == item.id }) {
                    items.append(item)
                }
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
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("清除") {
                        searchText = ""
                        dismiss()
                    }
                }
            }
        }
    }
}
#endif

/// 媒体卡片的异步视频缩略图；网络视频保持轻量占位，避免列表预加载整段流。
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

    /// 从本地视频第一秒异步生成缩略图；失败时保留渐变占位。
    private func loadThumbnail() async {
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

/// 添加网络直链或 HLS 地址的轻量表单。
private struct NetworkVideoSheet: View {
    let onAdd: (LibraryItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var urlString = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("视频地址") {
                    TextField("名称（可选）", text: $name)
                    TextField("https://…/video.mp4 或 playlist.m3u8", text: $urlString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red)
                    }
                }
                Section {
                    Text("支持 HTTPS、HLS，以及同一局域网内可直接访问的 HTTP 视频地址。需要账号密码的 WebDAV、SMB 和媒体服务器会在媒体源页统一管理。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("添加网络视频")
            .kanataInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加并播放") { addVideo() }
                        .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    /// 校验 URL、保存媒体条目并立即开始播放。
    private func addVideo() {
        let value = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased()) else {
            errorMessage = "请输入有效的 HTTP 或 HTTPS 地址"
            return
        }
        onAdd(LibraryItem(remoteURL: url, name: name))
        dismiss()
    }
}

/// 媒体库条目。M0 只保存书签与解析结果，扫描与刮削在 M1 补齐。
struct LibraryItem: Identifiable, Codable, Hashable {
    let id: String
    let displayName: String
    /// 安全作用域书签，App 重启后仍可访问原文件
    let bookmark: Data?
    /// 可直接交给 AVPlayer 的 HTTP(S) 视频或 HLS 地址。
    let remoteURLString: String?
    let title: String
    let season: Int?
    let episode: Int?

    /// 从文件选择器返回的地址创建条目，创建书签失败时返回 nil
    init?(url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? url.bookmarkData(options: .minimalBookmark) else { return nil }
        let parsed = TitleParser.parse(url.lastPathComponent)
        self.id = url.lastPathComponent
        self.displayName = url.lastPathComponent
        self.bookmark = bookmark
        self.remoteURLString = nil
        self.title = parsed.title
        self.season = parsed.season
        self.episode = parsed.episode
    }

    /// 创建一个网络视频条目。
    /// - Parameters:
    ///   - remoteURL: HTTP(S) 视频、HLS 或 NAS 直链。
    ///   - name: 用户提供的显示名称，空值时从 URL 推断。
    init(remoteURL: URL, name: String) {
        let inferredName = remoteURL.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? ""
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (!inferredName.isEmpty ? inferredName : (remoteURL.host ?? "网络视频"))
            : name.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = TitleParser.parse(displayName)
        self.id = "remote:\(remoteURL.absoluteString)"
        self.displayName = displayName
        self.bookmark = nil
        self.remoteURLString = remoteURL.absoluteString
        self.title = parsed.title
        self.season = parsed.season
        self.episode = parsed.episode
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
        return parts.joined(separator: " · ")
    }

    /// 解析书签取回文件地址，文件已失效时返回 nil
    func resolveURL() -> URL? {
        if let remoteURLString { return URL(string: remoteURLString) }
        guard let bookmark else { return nil }
        var isStale = false
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }
}

/// 媒体库的本地持久化。M0 用 UserDefaults，M1 换成 SQLite（docs/02 §5）。
enum LibraryStore {
    private static let key = "library.items"

    static func load() -> [LibraryItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([LibraryItem].self, from: data) else {
            return []
        }
        return items
    }

    static func save(_ items: [LibraryItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
