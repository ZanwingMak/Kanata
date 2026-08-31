import KanataCore
import SwiftUI
import UniformTypeIdentifiers

/// 媒体库首页。M0 只支持本地文件导入，NAS 与媒体服务器在 M1 接入（FR-IMP-003 起）。
struct LibraryView: View {
    @Environment(AppSettings.self) private var settings
    @State private var isImporting = false
    @State private var isShowingSettings = false
    @State private var items: [LibraryItem] = LibraryStore.load()
    @State private var playing: LibraryItem?
    @State private var importError: String?
    @State private var isProcessingImport = false

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView {
                        Label("还没有视频", systemImage: "film.stack")
                    } description: {
                        #if os(tvOS)
                        Text("Apple TV 仅显示已同步的网络媒体；请先在其他设备添加媒体源")
                        #else
                        Text("导入本地视频后，Kanata 会自动匹配并加载弹幕")
                        #endif
                    } actions: {
                        #if os(tvOS)
                        Button("打开设置") { isShowingSettings = true }
                            .buttonStyle(.borderedProminent)
                        #else
                        Button("导入视频") { isImporting = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(isProcessingImport)
                        #endif
                    }
                } else {
                    List {
                        ForEach(items) { item in
                            Button {
                                playing = item
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.displayName).font(.body).lineLimit(2)
                                    Text(item.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            items.remove(atOffsets: offsets)
                            LibraryStore.save(items)
                        }
                    }
                }
            }
            .navigationTitle("媒体库")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { isShowingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
                #if !os(tvOS)
                ToolbarItem(placement: .topBarTrailing) {
                    if isProcessingImport {
                        ProgressView()
                    } else {
                        Button { isImporting = true } label: {
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
            .task { await scanDocuments() }
        }
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

/// 媒体库条目。M0 只保存书签与解析结果，扫描与刮削在 M1 补齐。
struct LibraryItem: Identifiable, Codable, Hashable {
    let id: String
    let displayName: String
    /// 安全作用域书签，App 重启后仍可访问原文件
    let bookmark: Data
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
        return parts.joined(separator: " · ")
    }

    /// 解析书签取回文件地址，文件已失效时返回 nil
    func resolveURL() -> URL? {
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
