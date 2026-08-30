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

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView {
                        Label("还没有视频", systemImage: "film.stack")
                    } description: {
                        Text("导入本地视频后，Kanata 会自动匹配并加载弹幕")
                    } actions: {
                        Button("导入视频") { isImporting = true }
                            .buttonStyle(.borderedProminent)
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isImporting = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie, .item],
                allowsMultipleSelection: true
            ) { result in
                handleImport(result)
            }
            .alert("导入失败", isPresented: .constant(importError != nil)) {
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
            .task { scanDocuments() }
        }
    }

    /// 扫描 App 的 Documents 目录，收录通过文件共享或 AirDrop 放进来的视频（FR-IMP-002）
    private func scanDocuments() {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: documents,
                  includingPropertiesForKeys: nil
              ) else {
            return
        }
        let videoExtensions: Set<String> = ["mp4", "mkv", "mov", "m4v", "ts", "avi", "flv", "webm"]
        var changed = false
        for file in files where videoExtensions.contains(file.pathExtension.lowercased()) {
            guard !items.contains(where: { $0.id == file.lastPathComponent }),
                  let item = LibraryItem(url: file) else { continue }
            items.append(item)
            changed = true
        }
        if changed { LibraryStore.save(items) }
    }

    /// 处理文件选择结果，用安全作用域书签持久化访问权（FR-IMP-001）
    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                guard let item = LibraryItem(url: url) else {
                    importError = "无法为 \(url.lastPathComponent) 创建访问书签"
                    continue
                }
                if !items.contains(where: { $0.id == item.id }) {
                    items.append(item)
                }
            }
            LibraryStore.save(items)
        case .failure(let error):
            importError = error.localizedDescription
        }
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
