import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import SwiftUI
import UIKit

/// 一次 B 站二维码登录会话。
struct BilibiliQRCodeSession: Sendable {
    let url: URL
    let key: String
}

/// B 站二维码轮询的业务状态。
enum BilibiliQRCodePollResult: Sendable {
    case waitingForScan
    case waitingForConfirmation
    case expired
    case succeeded(cookie: String)
}

/// 调用 B 站网页二维码登录接口并提取成功后的 Cookie。
actor BilibiliQRCodeClient {
    private let session: URLSession

    /// 创建隔离 Cookie 的临时登录会话。
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    /// 生成二维码登录 URL 与轮询密钥。
    /// - Returns: 可显示、分享和在浏览器打开的登录会话。
    func generate() async throws -> BilibiliQRCodeSession {
        guard let url = URL(string: "https://passport.bilibili.com/x/passport-login/web/qrcode/generate") else {
            throw BilibiliQRCodeError.invalidResponse
        }
        let (data, response) = try await load(url)
        let envelope = try JSONDecoder().decode(GenerateEnvelope.self, from: data)
        guard envelope.code == 0,
              let value = envelope.data,
              let loginURL = URL(string: value.url),
              !value.key.isEmpty,
              response.statusCode == 200 else {
            throw BilibiliQRCodeError.upstream(envelope.message ?? "无法生成二维码")
        }
        return BilibiliQRCodeSession(url: loginURL, key: value.key)
    }

    /// 轮询扫码与确认状态，登录成功时返回可导入 Keychain 的 Cookie。
    /// - Parameter key: generate 接口返回的 qrcode_key。
    /// - Returns: 当前登录状态。
    func poll(key: String) async throws -> BilibiliQRCodePollResult {
        guard var components = URLComponents(
            string: "https://passport.bilibili.com/x/passport-login/web/qrcode/poll"
        ) else { throw BilibiliQRCodeError.invalidResponse }
        components.queryItems = [URLQueryItem(name: "qrcode_key", value: key)]
        guard let url = components.url else { throw BilibiliQRCodeError.invalidResponse }
        let (data, response) = try await load(url)
        let envelope = try JSONDecoder().decode(PollEnvelope.self, from: data)
        guard envelope.code == 0, let value = envelope.data else {
            throw BilibiliQRCodeError.upstream(envelope.message ?? "登录状态读取失败")
        }
        switch value.code {
        case 86101:
            return .waitingForScan
        case 86090:
            return .waitingForConfirmation
        case 86038:
            return .expired
        case 0:
            guard let cookie = Self.cookieHeader(response: response, redirectURL: value.url),
                  cookie.contains("SESSDATA=") else {
                throw BilibiliQRCodeError.missingCredential
            }
            return .succeeded(cookie: cookie)
        default:
            throw BilibiliQRCodeError.upstream(value.message ?? "未知登录状态 \(value.code)")
        }
    }

    /// 发起带浏览器标识的 HTTPS 请求并校验 HTTP 状态。
    /// - Parameter url: 二维码生成或轮询地址。
    /// - Returns: 响应体与 HTTP 响应。
    private func load(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Kanata/1",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw BilibiliQRCodeError.invalidResponse
        }
        return (data, http)
    }

    /// 从响应 Cookie 和成功跳转 URL 合并出应用使用的 Cookie 头。
    /// - Parameters:
    ///   - response: 登录成功的 HTTP 响应。
    ///   - redirectURL: 接口返回的跨域跳转地址。
    /// - Returns: 分号分隔的 Cookie，缺少内容时返回 nil。
    private static func cookieHeader(response: HTTPURLResponse, redirectURL: String?) -> String? {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String else { continue }
            headers[key] = String(describing: value)
        }
        var fields = Dictionary(uniqueKeysWithValues: HTTPCookie
            .cookies(withResponseHeaderFields: headers, for: response.url ?? URL(string: "https://bilibili.com")!)
            .map { ($0.name, $0.value) })
        if let redirectURL,
           let components = URLComponents(string: redirectURL) {
            for item in components.queryItems ?? [] where Self.credentialNames.contains(item.name) {
                if let value = item.value, !value.isEmpty, fields[item.name] == nil {
                    fields[item.name] = value
                }
            }
        }
        let values = credentialNames.compactMap { name in
            fields[name].map { "\(name)=\($0)" }
        }
        return values.isEmpty ? nil : values.joined(separator: "; ")
    }

    private static let credentialNames = ["SESSDATA", "bili_jct", "DedeUserID", "buvid3"]
}

/// B 站二维码登录响应解码模型。
private struct GenerateEnvelope: Decodable {
    struct Value: Decodable {
        let url: String
        let key: String

        private enum CodingKeys: String, CodingKey {
            case url
            case key = "qrcode_key"
        }
    }

    let code: Int
    let message: String?
    let data: Value?
}

/// B 站二维码状态响应解码模型。
private struct PollEnvelope: Decodable {
    struct Value: Decodable {
        let url: String?
        let code: Int
        let message: String?
    }

    let code: Int
    let message: String?
    let data: Value?
}

/// 二维码登录流程中的用户可读错误。
private enum BilibiliQRCodeError: LocalizedError {
    case invalidResponse
    case missingCredential
    case upstream(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "B 站登录接口响应无效"
        case .missingCredential: "扫码成功，但未取得登录凭证，请重试"
        case .upstream(let message): "B 站登录：\(message)"
        }
    }
}

/// 展示 B 站登录二维码并自动轮询登录状态。
struct BilibiliQRCodeLoginSheet: View {
    let onLogin: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var loginSession: BilibiliQRCodeSession?
    @State private var renderedQRCode: UIImage?
    @State private var statusText = "正在生成二维码…"
    @State private var errorText: String?
    @State private var didOpenBrowser = false
    private let client = BilibiliQRCodeClient()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                if let loginSession, let renderedQRCode {
                    Image(uiImage: renderedQRCode)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 260, height: 260)
                        .padding(18)
                        .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
                        .accessibilityLabel("B 站登录二维码")
                    Label(statusText, systemImage: statusSymbol)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.secondary.opacity(0.12), in: Capsule())
                    Text("使用哔哩哔哩 App 扫码并在手机上确认。登录结果会自动保存到本机 Keychain。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    #if !os(tvOS)
                    VStack(spacing: 12) {
                        Button {
                            didOpenBrowser = true
                            statusText = "浏览器登录后请返回 Kanata"
                            openURL(loginSession.url)
                        } label: {
                            Label("在浏览器中登录", systemImage: "safari")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        ShareLink(item: loginSession.url) {
                            Label("发送到其他设备", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("浏览器显示登录成功后，请返回 Kanata；本页会继续自动确认登录状态，无需复制 Cookie。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    #endif
                } else if loginSession != nil, errorText == nil {
                    ContentUnavailableView(
                        "二维码生成失败",
                        systemImage: "qrcode",
                        description: Text("请重新生成，或改用浏览器登录")
                    )
                } else if errorText == nil {
                    ProgressView(statusText)
                }
                if let errorText {
                    ContentUnavailableView {
                        Label("无法登录", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorText)
                    } actions: {
                        Button("重新生成") {
                            self.errorText = nil
                            Task { await beginLogin() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                Spacer(minLength: 0)
                }
                .frame(maxWidth: 520)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("扫码登录 B 站")
            .kanataInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await beginLogin() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, didOpenBrowser else { return }
                statusText = "已返回 Kanata，正在确认登录…"
            }
        }
    }

    /// 创建新二维码并每两秒轮询一次，直到登录、过期或任务取消。
    private func beginLogin() async {
        do {
            loginSession = nil
            renderedQRCode = nil
            errorText = nil
            didOpenBrowser = false
            statusText = "正在生成二维码…"
            let value = try await client.generate()
            loginSession = value
            renderedQRCode = Self.qrImage(from: value.url.absoluteString)
            statusText = "等待扫码"
            while !Task.isCancelled {
                switch try await client.poll(key: value.key) {
                case .waitingForScan:
                    statusText = "等待扫码"
                case .waitingForConfirmation:
                    statusText = "已扫码，请在手机上确认"
                case .expired:
                    throw BilibiliQRCodeError.upstream("二维码已过期，请重新生成")
                case .succeeded(let cookie):
                    statusText = "登录成功"
                    onLogin(cookie)
                    try? await Task.sleep(for: .milliseconds(600))
                    dismiss()
                    return
                }
                try await Task.sleep(for: .seconds(2))
            }
        } catch is CancellationError {
            return
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// 把登录 URL 生成为高容错、无插值的二维码图片。
    /// - Parameter value: 二维码承载的完整 URL。
    /// - Returns: 可直接显示的二维码图片。
    private static func qrImage(from value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "Q"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else {
            return nil
        }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let image = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }

    /// 根据登录状态选择易懂的状态图标。
    private var statusSymbol: String {
        if statusText.contains("成功") { return "checkmark.circle.fill" }
        if statusText.contains("确认") { return "iphone.radiowaves.left.and.right" }
        if statusText.contains("浏览器") { return "arrow.uturn.backward.circle" }
        return "qrcode.viewfinder"
    }
}
