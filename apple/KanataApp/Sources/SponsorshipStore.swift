import Observation
import StoreKit
import SwiftUI

/// 赞助内购商品的固定展示信息。
struct SponsorshipOption: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let fallbackPrice: String

    static let all: [SponsorshipOption] = [
        SponsorshipOption(
            id: "com.kanata.app.sponsor.099",
            title: "请我喝杯咖啡",
            detail: "一份轻轻的鼓励",
            fallbackPrice: "US$0.99"
        ),
        SponsorshipOption(
            id: "com.kanata.app.sponsor.299",
            title: "支持一次更新",
            detail: "感谢你支持持续完善",
            fallbackPrice: "US$2.99"
        ),
        SponsorshipOption(
            id: "com.kanata.app.sponsor.499",
            title: "送上一份鼓励",
            detail: "你的支持会让项目走得更远",
            fallbackPrice: "US$4.99"
        ),
        SponsorshipOption(
            id: "com.kanata.app.sponsor.999",
            title: "大力支持 Kanata",
            detail: "非常感谢这份慷慨支持",
            fallbackPrice: "US$9.99"
        )
    ]
}

/// 赞助购买流程需要展示的结果信息。
struct SponsorshipNotice {
    let title: String
    let message: String
}

/// 加载赞助商品、发起购买并处理 StoreKit 交易更新。
@MainActor
@Observable
final class SponsorshipStore {
    static let shared = SponsorshipStore()

    private(set) var productsByID: [String: Product] = [:]
    private(set) var isLoading = false
    private(set) var purchasingProductID: String?
    var notice: SponsorshipNotice?

    private var transactionUpdatesTask: Task<Void, Never>?

    /// 启动贯穿应用生命周期的交易监听，及时完成延迟到账的赞助交易。
    private init() {
        transactionUpdatesTask = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard let self else { return }
                await self.finishVerifiedTransaction(result)
            }
        }
    }

    /// 从 App Store 加载四档赞助商品。
    func loadProducts() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let productIDs = SponsorshipOption.all.map(\.id)
            let products = try await Product.products(for: productIDs)
            productsByID = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
            if products.isEmpty {
                notice = SponsorshipNotice(
                    title: "暂时无法加载",
                    message: "未能从 App Store 获取赞助项目，请稍后重试。"
                )
            }
        } catch {
            notice = SponsorshipNotice(
                title: "暂时无法加载",
                message: "连接 App Store 失败，请检查网络后重试。"
            )
        }
    }

    /// 发起指定赞助商品的购买，并只接受通过 StoreKit 校验的交易。
    /// - Parameter option: 用户选择的赞助档位。
    func purchase(_ option: SponsorshipOption) async {
        guard purchasingProductID == nil else { return }
        guard let product = productsByID[option.id] else {
            notice = SponsorshipNotice(
                title: "暂时无法购买",
                message: "该赞助项目尚未加载，请稍后重试。"
            )
            return
        }

        purchasingProductID = option.id
        defer { purchasingProductID = nil }

        do {
            let result = try await product.purchase()
            switch result {
            case let .success(verificationResult):
                let transaction = try verified(verificationResult)
                await transaction.finish()
                notice = SponsorshipNotice(
                    title: "感谢支持",
                    message: "赞助已完成。感谢你支持 Kanata 持续完善。"
                )
            case .pending:
                notice = SponsorshipNotice(
                    title: "等待确认",
                    message: "购买正在等待 App Store 或家长确认，完成后会自动处理。"
                )
            case .userCancelled:
                break
            @unknown default:
                notice = SponsorshipNotice(
                    title: "购买未完成",
                    message: "App Store 返回了暂不支持的购买状态，请稍后重试。"
                )
            }
        } catch {
            notice = SponsorshipNotice(
                title: "购买未完成",
                message: "交易未能通过验证或连接 App Store 失败，请稍后重试。"
            )
        }
    }

    /// 清除当前已展示的赞助结果提示。
    func clearNotice() {
        notice = nil
    }

    /// 完成交易监听器收到且通过 StoreKit 验证的交易。
    /// - Parameter result: StoreKit 推送的交易验证结果。
    private func finishVerifiedTransaction(_ result: VerificationResult<StoreKit.Transaction>) async {
        guard case let .verified(transaction) = result else { return }
        await transaction.finish()
    }

    /// 提取通过 StoreKit 签名校验的值，拒绝未验证交易。
    /// - Parameter result: StoreKit 验证结果。
    /// - Returns: 已验证的交易值。
    private func verified<Value>(_ result: VerificationResult<Value>) throws -> Value {
        switch result {
        case let .verified(value):
            return value
        case let .unverified(_, error):
            throw error
        }
    }
}

/// iPhone、iPad 与 Apple TV 共用的赞助内购页面。
struct SponsorshipView: View {
    @Environment(SponsorshipStore.self) private var store

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("支持 Kanata", systemImage: "heart.fill")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(KanataTheme.accent)
                    Text("如果 Kanata 对你有帮助，可以通过一次性赞助支持后续维护。")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            Section("选择赞助金额") {
                ForEach(SponsorshipOption.all) { option in
                    Button {
                        Task { await store.purchase(option) }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "heart.circle.fill")
                                .font(.title2)
                                .foregroundStyle(KanataTheme.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.title)
                                    .font(.headline)
                                Text(option.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 12)
                            if store.purchasingProductID == option.id {
                                ProgressView()
                            } else {
                                Text(store.productsByID[option.id]?.displayPrice ?? option.fallbackPrice)
                                    .font(.headline.monospacedDigit())
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(KanataSecondaryButtonStyle())
                    .disabled(store.purchasingProductID != nil || store.productsByID[option.id] == nil)
                }

                if store.isLoading {
                    HStack {
                        ProgressView()
                        Text("正在连接 App Store…")
                            .foregroundStyle(.secondary)
                    }
                } else if store.productsByID.count < SponsorshipOption.all.count {
                    Button("重新加载赞助项目") {
                        Task { await store.loadProducts() }
                    }
                }
            }

            Section {
                Text("赞助完全自愿，不会解锁任何功能、内容或服务。所有档位均为可重复购买的消耗型项目，实际金额以 App Store 显示为准。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(KanataTheme.accent)
        .kanataFormBackground()
        .navigationTitle("赞助 / 捐款")
        .kanataInlineNavigationTitle()
        .task { await store.loadProducts() }
        .alert(
            store.notice?.title ?? "提示",
            isPresented: Binding(
                get: { store.notice != nil },
                set: { if !$0 { store.clearNotice() } }
            )
        ) {
            Button("好", role: .cancel) { store.clearNotice() }
        } message: {
            Text(store.notice?.message ?? "")
        }
    }
}
