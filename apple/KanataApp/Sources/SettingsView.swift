import KanataCore
import SwiftUI

/// 设置页：网关配置与源状态（FR-SET-001 / FR-SET-002）
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var sources: [SourceStatus] = []

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section("弹幕网关") {
                    TextField("网关地址", text: $settings.gatewayURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("访问令牌", text: $settings.gatewayToken)
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
                }

                if !sources.isEmpty {
                    Section("弹幕源") {
                        ForEach(sources) { source in
                            HStack {
                                Circle()
                                    .fill(source.available ? .green : .orange)
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.id.rawValue)
                                    if let error = source.lastError {
                                        Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                    } else if source.requiresCredential && !source.hasCredential {
                                        Text("需要登录后获取完整弹幕")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if let latency = source.avgLatencyMs {
                                    Text("\(Int(latency))ms").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section {
                    Text("Kanata 不提供任何影视内容。弹幕数据来自各平台公开接口，版权归原平台与发送者所有，仅供个人观看时参考。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
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
}
