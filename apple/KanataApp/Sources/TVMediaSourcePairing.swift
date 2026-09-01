#if os(tvOS)
import CoreImage.CIFilterBuiltins
import Darwin
import Foundation
import Network
import Observation
import SwiftUI
import UIKit

/// 手机浏览器提交给 Apple TV 的一次性媒体源配置。
private struct TVMediaSourcePairingPayload: Sendable {
    let kind: MediaSourceKind
    let name: String
    let scheme: String
    let host: String
    let port: Int?
    let basePath: String
    let rootPath: String
    let username: String
    let password: String
    let otp: String

    /// 把结构化地址字段合成为可验证的服务器 URL。
    /// - Returns: 合法的 HTTP(S) URL；主机或协议无效时返回 nil。
    func serverURL() -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        components.port = port
        let path = basePath.trimmingCharacters(in: .whitespacesAndNewlines)
        components.path = path.isEmpty ? "" : (path.hasPrefix("/") ? path : "/\(path)")
        guard let url = components.url,
              components.host?.isEmpty == false,
              ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
        return url
    }
}

/// 临时局域网 HTTP 服务，仅在 Apple TV 配对页面可见期间接受一个带随机令牌的配置。
private final class TVPairingHTTPServer: @unchecked Sendable {
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.kanata.tv-pairing")
    private let onPayload: @Sendable (TVMediaSourcePairingPayload) -> Void

    /// 创建一个系统随机端口的 TCP 监听器。
    /// - Parameter onPayload: 收到合法表单后的回调。
    init(onPayload: @escaping @Sendable (TVMediaSourcePairingPayload) -> Void) throws {
        self.listener = try NWListener(using: .tcp, on: .any)
        self.onPayload = onPayload
    }

    /// 启动监听，并在端口就绪或失败时回传状态。
    /// - Parameter onState: 监听状态回调。
    func start(onState: @escaping @Sendable (Result<UInt16, Error>) -> Void) {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = self.listener.port?.rawValue {
                    onState(.success(port))
                }
            case .failed(let error):
                onState(.failure(error))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.receive(connection: connection, accumulated: Data())
        }
        listener.start(queue: queue)
    }

    /// 立即停止临时配对服务并取消所有新连接。
    func stop() {
        listener.cancel()
    }

    /// 累积一条 HTTP 请求，直到请求头与指定长度的表单正文完整。
    /// - Parameters:
    ///   - connection: 当前浏览器 TCP 连接。
    ///   - accumulated: 已接收的数据。
    private func receive(connection: NWConnection, accumulated: Data) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            if self.isCompleteHTTPRequest(buffer) || isComplete || error != nil {
                self.handle(requestData: buffer, connection: connection)
            } else {
                self.receiveNext(connection: connection, accumulated: buffer)
            }
        }
    }

    /// 继续读取已启动连接的下一段数据。
    /// - Parameters:
    ///   - connection: 当前浏览器 TCP 连接。
    ///   - accumulated: 已接收的数据。
    private func receiveNext(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            if self.isCompleteHTTPRequest(buffer) || isComplete || error != nil {
                self.handle(requestData: buffer, connection: connection)
            } else {
                self.receiveNext(connection: connection, accumulated: buffer)
            }
        }
    }

    /// 判断 HTTP 数据是否已经包含完整正文。
    /// - Parameter data: 已累计的原始请求。
    /// - Returns: GET 请求或正文长度满足 Content-Length 时返回 true。
    private func isCompleteHTTPRequest(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8),
              let headerRange = text.range(of: "\r\n\r\n") else { return false }
        let header = String(text[..<headerRange.lowerBound])
        guard header.hasPrefix("POST ") else { return true }
        let length = header
            .split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") }
            ?? 0
        return text[headerRange.upperBound...].utf8.count >= length
    }

    /// 路由配对页面与保存表单，并向浏览器返回明确结果。
    /// - Parameters:
    ///   - requestData: 完整 HTTP 请求。
    ///   - connection: 用于返回页面的 TCP 连接。
    private func handle(requestData: Data, connection: NWConnection) {
        guard let request = String(data: requestData, encoding: .utf8),
              let firstLine = request.split(separator: "\r\n", maxSplits: 1).first else {
            send(status: "400 Bad Request", html: resultPage("请求格式无效"), connection: connection)
            return
        }
        let components = firstLine.split(separator: " ")
        guard components.count >= 2,
              let requestURL = URLComponents(string: String(components[1])),
              requestURL.queryItems?.first(where: { $0.name == "token" })?.value == token else {
            send(status: "403 Forbidden", html: resultPage("配对码无效或已经过期"), connection: connection)
            return
        }
        if components[0] == "GET" {
            send(status: "200 OK", html: configurationPage(), connection: connection)
            return
        }
        guard components[0] == "POST",
              let body = request.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n").data(using: .utf8),
              let payload = parsePayload(body) else {
            send(status: "400 Bad Request", html: resultPage("请完整填写服务器地址与账号"), connection: connection)
            return
        }
        onPayload(payload)
        send(
            status: "200 OK",
            html: resultPage("已发送到 Apple TV，电视正在测试连接。成功后可直接关闭此页面。"),
            connection: connection
        )
    }

    /// 解析 URL 编码表单为媒体源配置。
    /// - Parameter data: POST 正文。
    /// - Returns: 必填字段有效时返回配置。
    private func parsePayload(_ data: Data) -> TVMediaSourcePairingPayload? {
        guard let body = String(data: data, encoding: .utf8) else { return nil }
        var fields: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first else { continue }
            fields[decode(String(key))] = decode(parts.count > 1 ? String(parts[1]) : "")
        }
        guard let kindRaw = fields["kind"],
              let kind = MediaSourceKind(rawValue: kindRaw),
              kind != .plex,
              let host = fields["host"],
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return TVMediaSourcePairingPayload(
            kind: kind,
            name: fields["name"] ?? "",
            scheme: fields["scheme"] == "https" ? "https" : "http",
            host: host,
            port: Int(fields["port"] ?? ""),
            basePath: fields["basePath"] ?? "",
            rootPath: fields["rootPath"] ?? "/",
            username: fields["username"] ?? "",
            password: fields["password"] ?? "",
            otp: fields["otp"] ?? ""
        )
    }

    /// 解码 application/x-www-form-urlencoded 字段。
    /// - Parameter value: 原始字段。
    /// - Returns: 还原空格和百分号编码后的字符串。
    private func decode(_ value: String) -> String {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
    }

    /// 返回适合手机使用的单页媒体源配置表单。
    /// - Returns: 不依赖外部资源的 HTML。
    private func configurationPage() -> String {
        """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>配置 Kanata Apple TV</title><style>
        :root{color-scheme:light dark}body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;max-width:620px;margin:auto;padding:24px;background:#07101f;color:#f7f9ff}h1{font-size:28px}p{color:#aab6ca;line-height:1.5}.card{background:#121d30;border:1px solid #263650;border-radius:20px;padding:20px}label{display:block;margin:16px 0 6px;font-weight:650}input,select{box-sizing:border-box;width:100%;font:inherit;padding:13px;border-radius:12px;border:1px solid #3b4d69;background:#0b1526;color:#fff}button{width:100%;margin-top:22px;padding:15px;border:0;border-radius:14px;background:linear-gradient(135deg,#2dbbdc,#1689bd);color:white;font-size:17px;font-weight:700}.row{display:grid;grid-template-columns:1fr 1fr;gap:12px}.hint{font-size:13px}</style></head><body>
        <h1>配置 Kanata Apple TV</h1><p>手机与 Apple TV 需连接同一可信 Wi‑Fi。本页面只在电视停留于配对界面时有效，连接成功后密码只保存到 Apple TV 的 Keychain。</p>
        <form class="card" method="post" action="/save?token=\(token)">
        <label>媒体源类型</label><select name="kind"><option value="webDAV">WebDAV</option><option value="jellyfin">Jellyfin</option><option value="emby">Emby</option><option value="synology">群晖 DSM</option></select>
        <label>显示名称（可选）</label><input name="name" placeholder="例如：客厅 NAS">
        <div class="row"><div><label>协议</label><select name="scheme"><option value="http">HTTP</option><option value="https">HTTPS</option></select></div><div><label>端口</label><input name="port" inputmode="numeric" placeholder="例如 8096"></div></div>
        <label>域名或 IP 地址</label><input name="host" required autocapitalize="none" placeholder="nas.local 或 192.168.1.20">
        <label>基础路径（可选）</label><input name="basePath" autocapitalize="none" placeholder="例如 /jellyfin">
        <label>WebDAV 起始目录（可选）</label><input name="rootPath" value="/" autocapitalize="none">
        <label>用户名</label><input name="username" autocomplete="username">
        <label>密码</label><input name="password" type="password" autocomplete="current-password">
        <label>群晖两步验证码（可选）</label><input name="otp" inputmode="numeric" autocomplete="one-time-code">
        <button type="submit">发送并测试连接</button></form>
        <p class="hint">Plex 请在电视端使用官方账号授权，以便自动发现并选择最快线路。</p></body></html>
        """
    }

    /// 返回手机浏览器提交后的结果页面。
    /// - Parameter message: 用户可读结果。
    /// - Returns: 简短 HTML 页面。
    private func resultPage(_ message: String) -> String {
        """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Kanata 配置</title><style>body{font-family:-apple-system,sans-serif;background:#07101f;color:#fff;padding:40px;line-height:1.6}.card{max-width:560px;margin:auto;background:#121d30;border-radius:20px;padding:24px}</style></head><body><div class="card"><h1>Kanata</h1><p>\(message)</p></div></body></html>
        """
    }

    /// 发送 UTF-8 HTML 响应并关闭当前连接。
    /// - Parameters:
    ///   - status: HTTP 状态行。
    ///   - html: 页面正文。
    ///   - connection: 当前浏览器连接。
    private func send(status: String, html: String, connection: NWConnection) {
        let body = Data(html.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Apple TV 配对流程状态，负责启动网页、验证媒体源并写入 Keychain。
@Observable
@MainActor
private final class TVMediaSourcePairingServer {
    var pairingURL: URL?
    var qrImage: UIImage?
    var statusText = "正在启动局域网配对…"
    var savedProfile: MediaSourceProfile?
    private var server: TVPairingHTTPServer?

    /// 启动一次新的随机令牌配对会话。
    func start() {
        guard server == nil else { return }
        do {
            let value = try TVPairingHTTPServer { [weak self] payload in
                Task { @MainActor in await self?.connect(payload) }
            }
            server = value
            value.start { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    switch result {
                    case .success(let port):
                        guard let host = Self.localIPv4Address(),
                              let url = URL(string: "http://\(host):\(port)/?token=\(value.token)") else {
                            self.statusText = "无法取得 Apple TV 的局域网地址，请确认已连接 Wi‑Fi"
                            return
                        }
                        self.pairingURL = url
                        self.qrImage = Self.qrCode(for: url.absoluteString)
                        self.statusText = "等待手机提交配置"
                    case .failure(let error):
                        self.statusText = "配对服务启动失败：\(error.localizedDescription)"
                    }
                }
            }
        } catch {
            statusText = "配对服务启动失败：\(error.localizedDescription)"
        }
    }

    /// 关闭局域网监听并让旧二维码立即失效。
    func stop() {
        server?.stop()
        server = nil
    }

    /// 验证手机提交的凭证，成功后写入媒体源历史和 Keychain。
    /// - Parameter payload: 手机表单提交的结构化配置。
    private func connect(_ payload: TVMediaSourcePairingPayload) async {
        guard savedProfile == nil, let url = payload.serverURL() else {
            statusText = "服务器地址无效，请在手机上检查后重新提交"
            return
        }
        statusText = "正在测试 \(payload.kind.title) 连接…"
        do {
            let secret: MediaSourceSecret
            switch payload.kind {
            case .webDAV:
                let root = payload.rootPath.isEmpty ? "/" : payload.rootPath
                guard let start = URL(string: root, relativeTo: url.appendingPathComponent(""))?.absoluteURL else {
                    throw MediaSourceError.invalidResponse
                }
                _ = try await WebDAVClient(username: payload.username, password: payload.password).list(directory: start)
                secret = MediaSourceSecret(password: payload.password, token: nil, userID: nil)
            case .jellyfin, .emby:
                secret = try await MediaBrowserClient().login(
                    server: url,
                    username: payload.username,
                    password: payload.password
                )
            case .synology:
                secret = try await SynologyFileStationClient().login(
                    server: url,
                    username: payload.username,
                    password: payload.password,
                    otp: payload.otp
                )
            case .plex:
                throw MediaSourceError.invalidResponse
            }
            let displayName = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let profile = MediaSourceProfileStore.upsert(
                kind: payload.kind,
                name: displayName.isEmpty ? "\(payload.kind.title) · \(url.host ?? "服务器")" : displayName,
                serverURL: url,
                username: payload.username,
                rootPath: payload.kind == .webDAV ? (payload.rootPath.isEmpty ? "/" : payload.rootPath) : nil,
                secret: secret
            )
            savedProfile = profile
            statusText = "“\(profile.name)”已连接并安全保存，可以返回媒体源列表"
            stop()
        } catch {
            statusText = "连接失败：\(error.localizedDescription)。请在手机上修改后重新提交"
        }
    }

    /// 读取当前设备首个可用的非回环 IPv4 地址。
    /// - Returns: 局域网 IPv4；未联网时返回 nil。
    private static func localIPv4Address() -> String? {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let first = addressList else { return nil }
        defer { freeifaddrs(addressList) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard current.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  (current.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(current.pointee.ifa_addr.pointee.sa_len)
            if getnameinfo(
                current.pointee.ifa_addr,
                length,
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 {
                let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                return String(decoding: bytes, as: UTF8.self)
            }
        }
        return nil
    }

    /// 生成适合电视远距离扫描的高对比度二维码。
    /// - Parameter text: 配对网页地址。
    /// - Returns: 生成失败时返回 nil。
    private static func qrCode(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// Apple TV 独立扫码配置页，避免使用遥控器填写长地址和密码。
struct TVMediaSourcePairingView: View {
    let onSaved: () -> Void
    @State private var pairing = TVMediaSourcePairingServer()

    var body: some View {
        VStack(spacing: 28) {
            Text("用手机配置媒体源")
                .font(.largeTitle.bold())
            Text("手机与 Apple TV 连接同一可信 Wi‑Fi，扫码后可在浏览器填写。")
                .font(.title3)
                .foregroundStyle(.secondary)
            if let image = pairing.qrImage {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 360, height: 360)
                    .padding(20)
                    .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(width: 400, height: 400)
            }
            Text(pairing.statusText)
                .font(.headline)
                .foregroundStyle(pairing.savedProfile == nil ? .primary : KanataTheme.success)
                .multilineTextAlignment(.center)
            if let url = pairing.pairingURL, pairing.savedProfile == nil {
                Text(url.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(50)
        .navigationTitle("手机配置")
        .task { pairing.start() }
        .onDisappear {
            if pairing.savedProfile != nil { onSaved() }
            pairing.stop()
        }
    }
}
#endif
