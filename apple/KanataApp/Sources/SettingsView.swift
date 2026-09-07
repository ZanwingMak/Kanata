import KanataCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// 设置页：网关配置与源状态（FR-SET-001 / FR-SET-002）
struct SettingsView: View {
    let usesParentNavigation: Bool
    @Environment(AppSettings.self) private var settings
    @Environment(CloudSyncStore.self) private var cloudSync
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
    @State private var dandanplayChannelResult: String?
    @State private var isTestingDandanplayChannel = false
    @State private var isShowingBilibiliQRCode = false
    @State private var versionTapCount = 0
    @State private var isShowingFeatureAccessNotice = false
    #if os(iOS)
    @State private var selectedIconName: String?
    @State private var iconResult: String?
    @State private var isChangingIcon = false
    #endif

    /// 创建设置界面；Apple TV 可沿用媒体库导航栈作为独立页面。
    /// - Parameter usesParentNavigation: 是否由外层 NavigationStack 提供返回操作。
    init(usesParentNavigation: Bool = false) {
        self.usesParentNavigation = usesParentNavigation
    }

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

    @ViewBuilder
    var body: some View {
        if usesParentNavigation {
            content
        } else {
            NavigationStack { content }
        }
    }

    /// 构建可由弹窗和 Apple TV 独立页面共同复用的设置表单。
    private var content: some View {
        @Bindable var settings = settings
        @Bindable var cloudSync = cloudSync
        return Form {
                Section("外观与个性化") {
                    Picker("主题色", selection: $settings.accentTheme) {
                        ForEach(KanataAccentTheme.allCases) { theme in
                            Label {
                                Text(theme.title)
                            } icon: {
                                Circle()
                                    .fill(theme.accent)
                                    .frame(width: 18, height: 18)
                            }
                            .tag(theme)
                        }
                    }
                    Picker("界面外观", selection: $settings.appearance) {
                        ForEach(KanataAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                    #if os(iOS)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("应用图标")
                            .font(.subheadline.weight(.semibold))
                        ScrollView(.horizontal) {
                            HStack(spacing: 14) {
                                ForEach(KanataAppIconChoice.all) { choice in
                                    Button {
                                        applyAppIcon(choice)
                                    } label: {
                                        VStack(spacing: 6) {
                                            Image(choice.previewName)
                                                .resizable()
                                                .scaledToFill()
                                                .frame(width: 62, height: 62)
                                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                                .overlay {
                                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                        .stroke(
                                                            selectedIconName == choice.alternateName
                                                                ? settings.accentTheme.accent
                                                                : Color.clear,
                                                            lineWidth: 3
                                                        )
                                                }
                                            Text(choice.title)
                                                .font(.caption)
                                                .foregroundStyle(.primary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isChangingIcon)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                    if let iconResult {
                        Text(iconResult)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    #endif
                }

                if settings.isFullFeatureAccessEnabled {
                    Section("开箱即用弹幕") {
                        Toggle(isOn: $settings.builtInBilibiliEnabled) {
                            settingsLabel("哔哩哔哩", symbol: "play.rectangle.on.rectangle")
                        }
                        Toggle(isOn: $settings.builtInPublicSourcesEnabled) {
                            settingsLabel("公共平台来源", symbol: "network")
                        }
                        if settings.builtInPublicSourcesEnabled {
                            Toggle(isOn: $settings.builtInIqiyiEnabled) {
                                settingsLabel("爱奇艺", symbol: "i.square")
                            }
                            Toggle(isOn: $settings.builtInQQEnabled) {
                                settingsLabel("腾讯视频", symbol: "play.square")
                            }
                            Toggle(isOn: $settings.builtInBahamutEnabled) {
                                settingsLabel("巴哈姆特动画疯", symbol: "sparkles.tv")
                            }
                        }
                        Text("无需服务器即可跨平台搜索作品、逐集选择并加载弹幕；网关不可用时仍可正常使用。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            Task { await testBuiltInSource() }
                        } label: {
                            HStack {
                                Label("测试全部内置来源", systemImage: "checkmark.circle")
                                if isTestingBuiltInSource { Spacer(); ProgressView() }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(KanataSecondaryButtonStyle())
                        .disabled(
                            (
                                !settings.builtInBilibiliEnabled
                                && (!settings.builtInPublicSourcesEnabled
                                    || (!settings.builtInIqiyiEnabled
                                        && !settings.builtInQQEnabled
                                        && !settings.builtInBahamutEnabled))
                            )
                            || isTestingBuiltInSource
                        )
                        if let builtInSourceResult {
                            Text(builtInSourceResult).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("弹弹play 渠道（自配置）") {
                    LabeledContent("AppID") {
                        TextField("请输入开放平台 AppID", text: $settings.dandanplayAppID)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("AppSecret") {
                        SecureField("请输入开放平台密钥", text: $settings.dandanplayAppSecret)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Toggle(isOn: $settings.dandanplayChannelEnabled) {
                        settingsLabel("启用弹弹play渠道", symbol: "key.horizontal")
                    }
                    .disabled(!settings.hasDandanplayConfiguration)
                    Button {
                        Task { await testDandanplayChannel() }
                    } label: {
                        HStack {
                            Label("测试弹弹play渠道", systemImage: "checkmark.shield")
                            if isTestingDandanplayChannel { Spacer(); ProgressView() }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(KanataSecondaryButtonStyle())
                    .disabled(!settings.hasDandanplayConfiguration || isTestingDandanplayChannel)
                    if settings.hasDandanplayConfiguration {
                        Button("清除渠道配置", role: .destructive) {
                            settings.clearDandanplayConfiguration()
                            dandanplayChannelResult = "弹弹play渠道配置已清除"
                        }
                    }
                    if let dandanplayChannelResult {
                        Text(dandanplayChannelResult).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Kanata 不内置或代填弹弹play凭据。AppID 与 AppSecret 由用户自行申请，并仅保存在当前设备的 Keychain。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("扩展弹幕网关（可选）") {
                    LabeledContent("网关地址") {
                        TextField("http://192.168.1.7:9321", text: $settings.gatewayURLString)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                    LabeledContent("访问令牌") {
                        SecureField("可选", text: $settings.gatewayToken)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Label("测试连接", systemImage: "bolt.horizontal.circle")
                            if isTesting { Spacer(); ProgressView() }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(KanataSecondaryButtonStyle())
                    .disabled(isTesting)
                    if let testResult {
                        Text(testResult).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("用于连接自托管聚合接口及扩展来源。未配置时不影响设备上的其他弹幕渠道。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if settings.isFullFeatureAccessEnabled, !sources.isEmpty {
                    Section("弹幕源") {
                        ForEach(sources) { source in
                            sourceStatusRow(source)
                        }
                    }
                }

                if settings.isFullFeatureAccessEnabled {
                    Section("B 站登录") {
                        if settings.hasBilibiliCredential {
                            Label("已在 Keychain 保存登录凭证", systemImage: "checkmark.shield")
                                .foregroundStyle(.green)
                        }
                        Button {
                            isShowingBilibiliQRCode = true
                        } label: {
                            KanataRowLabel(
                                title: settings.hasBilibiliCredential ? "重新登录 B 站" : "扫码或浏览器登录",
                                detail: "无需复制 Cookie，登录后自动返回确认",
                                symbol: "qrcode.viewfinder"
                            )
                        }
                        .buttonStyle(KanataSecondaryButtonStyle())
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
                        .buttonStyle(KanataSecondaryButtonStyle())
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
                }

                Section("iCloud 同步") {
                    Toggle(isOn: $cloudSync.isEnabled) {
                        settingsLabel("跨设备同步", symbol: "icloud")
                    }
                    if cloudSync.isEnabled {
                        Button {
                            Task { await cloudSync.syncNow() }
                        } label: {
                            HStack {
                                Label("立即同步", systemImage: "arrow.triangle.2.circlepath.icloud")
                                if cloudSync.isSyncing { Spacer(); ProgressView() }
                            }
                        }
                        .buttonStyle(KanataSecondaryButtonStyle())
                        .disabled(cloudSync.isSyncing)
                        if let lastSyncAt = cloudSync.lastSyncAt {
                            LabeledContent("最近同步") {
                                Text(lastSyncAt.formatted(date: .abbreviated, time: .shortened))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let statusMessage = cloudSync.statusMessage {
                            Text(statusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("同步网络媒体库、媒体源地址、播放进度、收藏、剧集排序与忽略、弹幕匹配和显示偏好。密码、令牌与本地文件不会上传；新设备首次打开媒体源时可能需要重新登录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                storageSection

                Section("关于 Kanata") {
                    Button(action: registerVersionTap) {
                        LabeledContent("版本", value: appVersionLabel)
                    }
                    .foregroundStyle(.primary)
                    LabeledContent("许可", value: "请参阅开源仓库")
                    Link(destination: openSourceURL) {
                        LabeledContent("开源地址", value: "github.com/ZanwingMak/Kanata")
                    }
                }

                Section {
                    Text("Kanata 不提供任何影视内容，也不提供弹弹play开放平台凭据。用户配置弹弹play渠道后，数据来源会标注为“弹弹play开放弹幕网络”；其他弹幕版权归对应平台与发送者所有，仅供个人观看时参考。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(settings.accentTheme.accent)
            .kanataFormBackground()
            .navigationTitle("设置")
            .kanataInlineNavigationTitle()
            .toolbar {
                if !usesParentNavigation {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                            .buttonStyle(.plain)
                            .kanataToolbarTextButton()
                    }
                }
            }
            .task { await refreshStorageUsage() }
            #if os(iOS)
            .onAppear { selectedIconName = UIApplication.shared.alternateIconName }
            #endif
            .onChange(of: settings.onlineDanmakuCacheLimitMB) { _, newValue in
                Task { await applyCacheLimit(newValue) }
            }
            .kanataModal(isPresented: $isShowingBilibiliQRCode) {
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
            .alert("功能已解锁", isPresented: $isShowingFeatureAccessNotice) {
                Button("好", role: .cancel) {}
            } message: {
                Text("完整功能与弹幕功能已开启。")
            }
    }

    /// 生成设置行统一的图标与文本标签，保证开关和按钮左缘一致。
    /// - Parameters:
    ///   - title: 设置项名称。
    ///   - symbol: SF Symbol 名称。
    /// - Returns: 使用固定图标宽度的标签。
    private func settingsLabel(_ title: String, symbol: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .frame(width: 24)
                .foregroundStyle(settings.accentTheme.accent)
        }
    }

    /// 记录版本号连续点击次数，并在达到要求时开放完整功能。
    private func registerVersionTap() {
        guard !settings.isFullFeatureAccessEnabled else { return }
        versionTapCount += 1
        guard versionTapCount >= 15 else { return }
        versionTapCount = 0
        if settings.enableFullFeatureAccess() {
            isShowingFeatureAccessNotice = true
        }
    }

    /// 返回当前 App 的市场版本与构建号。
    private var appVersionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(version) (\(build))"
    }

    /// 项目公开源代码仓库地址。
    private var openSourceURL: URL {
        URL(string: "https://github.com/ZanwingMak/Kanata")!
    }

    #if os(iOS)
    /// 调用系统接口切换 App 图标，并在设置页同步展示结果。
    /// - Parameter choice: 用户选择的主图标或备用图标。
    private func applyAppIcon(_ choice: KanataAppIconChoice) {
        guard UIApplication.shared.supportsAlternateIcons,
              selectedIconName != choice.alternateName,
              !isChangingIcon else { return }
        isChangingIcon = true
        UIApplication.shared.setAlternateIconName(choice.alternateName) { error in
            Task { @MainActor in
                isChangingIcon = false
                if let error {
                    iconResult = "图标切换失败：\(error.localizedDescription)"
                } else {
                    selectedIconName = choice.alternateName
                    iconResult = "已切换为“\(choice.title)”图标"
                }
            }
        }
    }
    #endif

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
        if settings.gatewayURLString.localizedCaseInsensitiveContains("kanata") {
            testResult = "功能已解锁"
            if settings.enableFullFeatureAccess() {
                versionTapCount = 0
                isShowingFeatureAccessNotice = true
            }
            return
        }
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

    /// 检查无需网关的内置弹幕来源是否可访问。
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
            if settings.builtInIqiyiEnabled {
                statuses.append("爱奇艺\(health[.iqiyi] == true ? "可用" : "失败")")
            }
            if settings.builtInQQEnabled {
                statuses.append("腾讯视频\(health[.qq] == true ? "可用" : "失败")")
            }
            if settings.builtInBahamutEnabled {
                statuses.append("巴哈姆特\(health[.bahamut] == true ? "可用" : "失败")")
            }
        }
        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1_000)
        builtInSourceResult = "\(statuses.joined(separator: " · ")) · \(elapsed)ms"
    }

    /// 使用用户填写的 AppID 与 AppSecret 检查弹弹play开放平台渠道。
    private func testDandanplayChannel() async {
        guard settings.hasDandanplayConfiguration else {
            dandanplayChannelResult = "请先填写完整的 AppID 与 AppSecret"
            return
        }
        settings.dandanplayChannelEnabled = true
        guard let client = settings.makeDandanplayChannelClient() else {
            settings.dandanplayChannelEnabled = false
            dandanplayChannelResult = "弹弹play渠道配置不完整"
            return
        }
        isTestingDandanplayChannel = true
        defer { isTestingDandanplayChannel = false }
        let startedAt = Date()
        let available = await client.health()
        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1_000)
        settings.dandanplayChannelEnabled = available
        dandanplayChannelResult = available
            ? "连接成功 · \(elapsed)ms · 渠道已启用"
            : "连接失败 · 请检查 AppID、AppSecret 与开放平台额度"
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

#if os(iOS)
/// 设置页可选择的系统 App 图标；nil 表示主图标。
private struct KanataAppIconChoice: Identifiable {
    let alternateName: String?
    let previewName: String
    let title: String

    var id: String { alternateName ?? "AppIcon" }

    static let all = [
        KanataAppIconChoice(
            alternateName: nil,
            previewName: "AppIconPreviewDefault",
            title: "星河"
        ),
        KanataAppIconChoice(
            alternateName: "AppIconAurora",
            previewName: "AppIconPreviewAurora",
            title: "极光"
        ),
        KanataAppIconChoice(
            alternateName: "AppIconSunset",
            previewName: "AppIconPreviewSunset",
            title: "落日"
        ),
    ]
}
#endif
