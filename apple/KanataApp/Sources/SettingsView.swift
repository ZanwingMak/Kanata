import KanataCore
import SwiftUI

/// 设置页：网关配置与源状态（FR-SET-001 / FR-SET-002）
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var sources: [SourceStatus] = []
    @State private var onlineCacheUsage = DanmakuStorageUsage(fileCount: 0, totalBytes: 0)
    @State private var localDanmakuUsage = DanmakuStorageUsage(fileCount: 0, totalBytes: 0)
    @State private var storageResult: String?
    @State private var clearTarget: ClearTarget?
    @State private var bilibiliCookieInput = ""
    @State private var bilibiliResult: String?
    @State private var isVerifyingBilibili = false
    @State private var builtInSourceResult: String?
    @State private var isTestingBuiltInSource = false
    @State private var isShowingBilibiliQRCode = false

    private enum ClearTarget {
        case onlineCache
        case importedDanmaku
        case bilibiliCredential

        var title: String {
            switch self {
            case .onlineCache: "清除在线弹幕缓存？"
            case .importedDanmaku: "删除全部导入弹幕？"
            case .bilibiliCredential: "清除 B 站登录凭证？"
            }
        }

        var actionTitle: String {
            switch self {
            case .onlineCache: "清除缓存"
            case .importedDanmaku: "全部删除"
            case .bilibiliCredential: "退出登录"
            }
        }
    }

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section("开箱即用弹幕") {
                    Toggle("内置哔哩哔哩来源", isOn: $settings.builtInBilibiliEnabled)
                    Toggle("内置爱奇艺与腾讯视频来源", isOn: $settings.builtInPublicSourcesEnabled)
                    Text("无需服务器即可跨平台搜索作品、逐集选择并加载弹幕；网关不可用时仍可正常使用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await testBuiltInSource() }
                    } label: {
                        HStack {
                            Text("测试全部内置来源")
                            if isTestingBuiltInSource { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(
                        (!settings.builtInBilibiliEnabled && !settings.builtInPublicSourcesEnabled)
                        || isTestingBuiltInSource
                    )
                    if let builtInSourceResult {
                        Text(builtInSourceResult).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("扩展弹幕网关（可选）") {
                    TextField("例如 http://192.168.1.7:9321", text: $settings.gatewayURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("访问令牌", text: $settings.gatewayToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Text("测试连接")
                            if isTesting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isTesting)
                    if let testResult {
                        Text(testResult).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("用于扩展弹弹play、自定义聚合接口及后续来源。未配置时不影响哔哩哔哩、爱奇艺和腾讯视频内置来源。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !sources.isEmpty {
                    Section("弹幕源") {
                        ForEach(sources) { source in
                            sourceStatusRow(source)
                        }
                    }
                }

                Section("B 站登录") {
                    if settings.hasBilibiliCredential {
                        Label("已在 Keychain 保存登录凭证", systemImage: "checkmark.shield")
                            .foregroundStyle(.green)
                    }
                    Button {
                        isShowingBilibiliQRCode = true
                    } label: {
                        Label(
                            settings.hasBilibiliCredential ? "重新扫码登录" : "扫码登录",
                            systemImage: "qrcode.viewfinder"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    #if os(tvOS)
                    SecureField("Cookie 备用登录", text: $bilibiliCookieInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    #else
                    DisclosureGroup("Cookie 备用登录") {
                        SecureField("粘贴完整 Cookie", text: $bilibiliCookieInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    #endif
                    Button {
                        Task { await verifyBilibiliCredential() }
                    } label: {
                        HStack {
                            Text(bilibiliCookieInput.isEmpty ? "验证已保存凭证" : "导入并验证")
                            if isVerifyingBilibili { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(
                        isVerifyingBilibili
                        || (bilibiliCookieInput.isEmpty && !settings.hasBilibiliCredential)
                    )
                    if settings.hasBilibiliCredential {
                        Button("退出 B 站登录", role: .destructive) {
                            clearTarget = .bilibiliCredential
                        }
                    }
                    if let bilibiliResult {
                        Text(bilibiliResult).font(.caption).foregroundStyle(.secondary)
                    }
                }

                storageSection

                Section {
                    Text("Kanata 不提供任何影视内容。使用弹弹play数据时，来源标注为“弹弹play开放弹幕网络”；其他弹幕版权归对应平台与发送者所有，仅供个人观看时参考。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .kanataInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await refreshStorageUsage() }
            .onChange(of: settings.onlineDanmakuCacheLimitMB) { _, newValue in
                Task { await applyCacheLimit(newValue) }
            }
            .sheet(isPresented: $isShowingBilibiliQRCode) {
                BilibiliQRCodeLoginSheet { cookie in
                    if settings.importBilibiliCookie(cookie) {
                        bilibiliResult = "扫码登录成功，凭证已保存"
                        Task { await verifyBilibiliCredential() }
                    } else {
                        bilibiliResult = "扫码完成，但凭证格式无效，请重试"
                    }
                }
            }
            .alert(
                clearTarget?.title ?? "确认清理",
                isPresented: Binding(
                    get: { clearTarget != nil },
                    set: { if !$0 { clearTarget = nil } }
                )
            ) {
                Button("取消", role: .cancel) { clearTarget = nil }
                Button(clearTarget?.actionTitle ?? "删除", role: .destructive) {
                    let target = clearTarget
                    clearTarget = nil
                    Task { await clearConfirmedData(target) }
                }
            } message: {
                Text(clearConfirmationMessage)
            }
        }
    }

    /// 构建弹幕缓存与导入文件的存储管理分区。
    private var storageSection: some View {
        @Bindable var settings = settings
        return Section("弹幕存储") {
            Picker("在线缓存上限", selection: $settings.onlineDanmakuCacheLimitMB) {
                Text("100 MB").tag(100)
                Text("250 MB").tag(250)
                Text("500 MB").tag(500)
                Text("1 GB").tag(1_024)
            }
            LabeledContent("在线缓存") {
                Text(storageLabel(onlineCacheUsage))
                    .foregroundStyle(.secondary)
            }
            LabeledContent("导入弹幕") {
                Text(storageLabel(localDanmakuUsage))
                    .foregroundStyle(.secondary)
            }
            Button("清除在线缓存", role: .destructive) {
                clearTarget = .onlineCache
            }
            .disabled(onlineCacheUsage.fileCount == 0)
            Button("删除全部导入弹幕", role: .destructive) {
                clearTarget = .importedDanmaku
            }
            .disabled(localDanmakuUsage.fileCount == 0)
            if let storageResult {
                Text(storageResult).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// 把存储统计拼成稳定的简短文案。
    /// - Parameter usage: 文件数量与字节数统计。
    /// - Returns: “N 个 · 容量”格式。
    private func storageLabel(_ usage: DanmakuStorageUsage) -> String {
        "\(usage.fileCount) 个 · \(formatBytes(usage.totalBytes))"
    }

    /// 渲染单个弹幕来源的可用状态与延迟。
    /// - Parameter source: 网关返回的来源状态。
    /// - Returns: 设置页中的状态行。
    private func sourceStatusRow(_ source: SourceStatus) -> some View {
        HStack {
            Circle()
                .fill(source.available ? .green : .orange)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.id.displayName)
                if let error = source.lastError {
                    Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                } else if source.requiresCredential && !source.hasCredential {
                    Text("需要登录后获取完整弹幕")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let latency = source.avgLatencyMs {
                Text(String(format: "%.0fms", latency))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 测试网关连通性并拉取源状态
    private func testConnection() async {
        guard let client = settings.makeClient() else {
            testResult = "网关地址格式不正确"
            return
        }
        isTesting = true
        defer { isTesting = false }
        let startedAt = Date()
        do {
            _ = try await client.health()
            sources = try await client.sources()
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            let usable = sources.filter(\.available).count
            testResult = "连接成功 · \(elapsed)ms · \(usable)/\(sources.count) 个源可用"
        } catch let error as GatewayError {
            testResult = "连接失败：\(error.errorMessage)"
        } catch {
            testResult = "连接失败：\(error.localizedDescription)"
        }
    }

    /// 检查无需网关的哔哩哔哩、爱奇艺与腾讯视频来源是否可访问。
    private func testBuiltInSource() async {
        let bilibiliClient = settings.makeBuiltInBilibiliClient()
        let publicClient = settings.makeBuiltInPublicDanmakuClient()
        guard bilibiliClient != nil || publicClient != nil else {
            builtInSourceResult = "内置来源已关闭"
            return
        }
        isTestingBuiltInSource = true
        defer { isTestingBuiltInSource = false }
        let startedAt = Date()
        var statuses: [String] = []
        if let bilibiliClient {
            statuses.append("哔哩哔哩\(await bilibiliClient.health() ? "可用" : "失败")")
        }
        if let publicClient {
            let health = await publicClient.health()
            statuses.append("爱奇艺\(health[.iqiyi] == true ? "可用" : "失败")")
            statuses.append("腾讯视频\(health[.qq] == true ? "可用" : "失败")")
        }
        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1_000)
        builtInSourceResult = "\(statuses.joined(separator: " · ")) · \(elapsed)ms"
    }

    /// 导入可选 Cookie 后，通过网关校验 B 站登录态。
    private func verifyBilibiliCredential() async {
        if !bilibiliCookieInput.isEmpty,
           !settings.importBilibiliCookie(bilibiliCookieInput) {
            bilibiliResult = "Cookie 中未找到有效的 SESSDATA"
            return
        }
        isVerifyingBilibili = true
        defer { isVerifyingBilibili = false }
        if let directClient = settings.makeBuiltInBilibiliClient() {
            do {
                let result = try await directClient.verifyCredential()
                if result.valid {
                    bilibiliCookieInput = ""
                    bilibiliResult = result.displayName.map { "登录有效 · \($0)" } ?? "登录有效"
                } else {
                    bilibiliResult = "凭证无效：\(result.message ?? "请重新获取 Cookie")"
                }
            } catch {
                bilibiliResult = "校验失败：\(error.localizedDescription)"
            }
            return
        }
        guard let client = settings.makeClient() else {
            bilibiliResult = "请启用内置来源或填写有效的网关地址"
            return
        }
        do {
            let result = try await client.verifyCredential(source: .bilibili)
            if result.valid {
                bilibiliCookieInput = ""
                bilibiliResult = result.displayName.map { "登录有效 · \($0)" } ?? "登录有效"
            } else {
                bilibiliResult = "凭证无效：\(result.message ?? "请重新获取 Cookie")"
            }
        } catch let error as GatewayError {
            bilibiliResult = "校验失败：\(error.errorMessage)"
        } catch {
            bilibiliResult = "校验失败：\(error.localizedDescription)"
        }
    }

    /// 刷新在线缓存与用户导入弹幕的空间统计。
    private func refreshStorageUsage() async {
        onlineCacheUsage = await DanmakuCacheStore.shared.usage()
        localDanmakuUsage = await LocalDanmakuStore.shared.usage()
    }

    /// 应用新的在线缓存容量上限并立即裁剪旧文件。
    private func applyCacheLimit(_ megabytes: Int) async {
        do {
            try await DanmakuCacheStore.shared.trim(to: Int64(megabytes) * 1024 * 1024)
            await refreshStorageUsage()
            storageResult = "缓存上限已更新"
        } catch {
            storageResult = "无法调整缓存：\(error.localizedDescription)"
        }
    }

    /// 根据用户确认清理在线缓存或全部导入弹幕。
    private func clearConfirmedData(_ target: ClearTarget?) async {
        do {
            switch target {
            case .onlineCache:
                try await DanmakuCacheStore.shared.removeAll()
                storageResult = "在线缓存已清除"
            case .importedDanmaku:
                try await LocalDanmakuStore.shared.removeAll()
                storageResult = "导入弹幕已全部删除"
            case .bilibiliCredential:
                settings.clearBilibiliCredential()
                bilibiliCookieInput = ""
                bilibiliResult = "B 站登录凭证已清除"
            case nil:
                return
            }
            await refreshStorageUsage()
        } catch {
            storageResult = "清理失败：\(error.localizedDescription)"
        }
    }

    /// 把字节数格式化为适合设置页显示的容量文本。
    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// 返回当前清理操作对应的不可逆影响说明。
    private var clearConfirmationMessage: String {
        switch clearTarget {
        case .importedDanmaku:
            "所有视频关联的用户导入弹幕都会被删除，此操作无法撤销。"
        case .onlineCache:
            "只清除可重新下载的在线弹幕，不影响用户导入文件。"
        case .bilibiliCredential:
            "凭证会从本机 Keychain 删除，之后将以匿名状态访问 B 站。"
        case nil:
            ""
        }
    }
}
