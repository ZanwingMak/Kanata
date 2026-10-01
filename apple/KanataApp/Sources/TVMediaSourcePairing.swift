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
    let serverAddress: String
    let rootPath: String
    let username: String
    let password: String
    let otp: String

    /// 解析完整网址或主机地址，并补上当前媒体源的常用协议与端口。
    /// - Returns: 合法的 HTTP(S) URL；主机或协议无效时返回 nil。
    func serverURL() -> URL? {
        let address = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return nil }
        let hasScheme = address.contains("://")
        let preferredScheme = kind == .webDAV || kind == .synology ? "https" : "http"
        guard var components = URLComponents(string: hasScheme ? address : "\(preferredScheme)://\(address)"),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else { return nil }
        if !hasScheme, components.port == nil { components.port = defaultServerPort(for: scheme) }
        return components.url
    }

    /// 手机未指定端口时按媒体源和协议选择连接端口。
    private func defaultServerPort(for scheme: String) -> Int {
        let secure = scheme == "https"
        switch kind {
        case .webDAV: return secure ? 5006 : 5005
        case .jellyfin, .emby: return secure ? 8920 : 8096
        case .plex: return 32400
        case .synology: return secure ? 5001 : 5000
        }
    }
}

/// 临时局域网 HTTP 服务，仅在 Apple TV 配对页面可见期间接受一个带随机令牌的配置。
private final class TVPairingHTTPServer: @unchecked Sendable {
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.kanata.tv-pairing")
    private let onPayload: @Sendable (TVMediaSourcePairingPayload) async -> (Bool, String)

    /// 创建一个系统随机端口的 TCP 监听器。
    /// - Parameter onPayload: 收到合法表单后的回调。
    init(onPayload: @escaping @Sendable (TVMediaSourcePairingPayload) async -> (Bool, String)) throws {
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
              let payload = parsePayload(body),
              payload.serverURL() != nil else {
            sendJSON(success: false, message: "服务器地址无效，请填写完整网址或域名/IP 地址。", connection: connection)
            return
        }
        Task { [weak self] in
            let (success, message) = await self?.onPayload(payload) ?? (false, "配对已结束，请重新扫码。")
            self?.sendJSON(success: success, message: message, connection: connection)
        }
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
              let address = fields["serverAddress"],
              !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return TVMediaSourcePairingPayload(
            kind: kind,
            name: fields["name"] ?? "",
            serverAddress: address,
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
        <!doctype html>
        <html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <title>配置 Kanata Apple TV</title><style>
        :root{color-scheme:dark;font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;background:#080d17;color:#f5f8ff}
        *{box-sizing:border-box}body{max-width:560px;margin:0 auto;padding:28px 20px calc(32px + env(safe-area-inset-bottom))}
        h1{font-size:29px;letter-spacing:-.03em;margin:8px 0 8px}p{margin:0;color:#9eacc2;line-height:1.55}.intro{margin-bottom:24px}
        .eyebrow{color:#52d4c7;font-size:13px;font-weight:750;letter-spacing:.12em}.card{background:#151d2b;border:1px solid #2d3a4f;border-radius:22px;padding:22px;box-shadow:0 16px 40px #0004}
        .field{margin:0 0 20px}.field:last-of-type{margin-bottom:0}.field[hidden]{display:none}label{display:block;margin-bottom:8px;font-size:15px;font-weight:680}
        input,select{display:block;width:100%;min-height:52px;padding:13px 15px;border:1px solid #43516a;border-radius:13px;background:#0c1422;color:#fff;font:inherit;font-size:16px;outline:none}
        input:focus,select:focus{border-color:#52d4c7;box-shadow:0 0 0 3px #52d4c72a}input::placeholder{color:#8591a4}
        .hint{font-size:13px;margin-top:7px}.example{color:#c2d0e3}button{width:100%;min-height:54px;margin-top:24px;border:0;border-radius:14px;background:#58d9cb;color:#092322;font-size:17px;font-weight:750}
        button:disabled{opacity:.55}.message{margin-top:16px;padding:13px 15px;border-radius:12px;background:#13352f;color:#b9f2e9;line-height:1.5}.message.error{background:#3b2528;color:#ffd4d5}
        .foot{font-size:13px;margin:20px 4px 0}a{color:#80dfd5}
        </style></head><body>
        <div class="eyebrow">KANATA · APPLE TV</div><h1>用手机添加媒体源</h1>
        <p class="intro">填写服务器地址与登录信息，Kanata 会在电视上测试连接。请让电视保持在二维码页面。</p>
        <form id="source-form" class="card" method="post" action="/save?token=\(token)">
          <div class="field"><label for="kind">媒体源类型</label><select id="kind" name="kind"><option value="webDAV">WebDAV</option><option value="jellyfin">Jellyfin</option><option value="emby">Emby</option><option value="synology">群晖 DSM</option></select></div>
          <div class="field"><label for="name">显示名称 <span class="hint">（可选）</span></label><input id="name" name="name" autocomplete="off" placeholder="例如：客厅 NAS"></div>
          <div class="field"><label for="serverAddress">服务器地址</label><input id="serverAddress" name="serverAddress" required spellcheck="false" autocapitalize="none" autocorrect="off" inputmode="url" placeholder="https://nas.example.com:5006" aria-describedby="address-hint"><p id="address-hint" class="hint">可粘贴完整网址，端口与子路径会保留。只填域名/IP 时将使用该类型的常用协议和端口。</p></div>
          <div id="root-field" class="field"><label for="rootPath">媒体起始目录 <span class="hint">（可选）</span></label><input id="rootPath" name="rootPath" value="/" spellcheck="false" autocapitalize="none" autocorrect="off" placeholder="例如 /video"><p class="hint">从此目录开始浏览媒体。<span class="example">/</span> 表示 WebDAV 根目录；它与服务器网址里的部署路径不同。</p></div>
          <div class="field"><label for="username">用户名</label><input id="username" name="username" autocomplete="username" autocapitalize="none" autocorrect="off" placeholder="服务器账号"></div>
          <div class="field"><label for="password">密码</label><input id="password" name="password" type="password" autocomplete="current-password" placeholder="服务器密码"></div>
          <div id="otp-field" class="field" hidden><label for="otp">群晖两步验证码 <span class="hint">（如已开启）</span></label><input id="otp" name="otp" inputmode="numeric" autocomplete="one-time-code"></div>
          <button id="submit" type="submit">测试连接并保存到电视</button><div id="message" class="message" role="status" aria-live="polite" hidden></div>
        </form>
        <p class="foot">手机和 Apple TV 需连接同一可信 Wi‑Fi。密码只会保存在 Apple TV 的 Keychain。Plex 请在电视上授权。</p>
        <script>
        const form=document.getElementById('source-form'),kind=document.getElementById('kind'),address=document.getElementById('serverAddress'),message=document.getElementById('message'),submit=document.getElementById('submit');
        /** 按媒体源类型显示对应字段及地址示例。 */
        function updateKind(){const value=kind.value;document.getElementById('root-field').hidden=value!=='webDAV';document.getElementById('otp-field').hidden=value!=='synology';address.placeholder=({webDAV:'https://nas.example.com:5006',jellyfin:'http://nas.example.com:8096',emby:'http://nas.example.com:8096',synology:'https://nas.example.com:5001'})[value];document.getElementById('username').required=value!=='webDAV';document.getElementById('password').required=value!=='webDAV';}
        /** 在表单内显示电视返回的连接结果。 */
        function showMessage(value,error){message.hidden=false;message.className='message'+(error?' error':'');message.textContent=value;message.scrollIntoView({block:'nearest',behavior:'smooth'});}
        /** 保留输入内容并等待电视完成实际连接测试。 */
        async function sendForm(event){event.preventDefault();if(!form.reportValidity())return;submit.disabled=true;submit.textContent='电视正在测试连接…';showMessage('正在连接，请保持电视停留在二维码页面。',false);try{const response=await fetch(form.action,{method:'POST',body:new URLSearchParams(new FormData(form)),headers:{'Content-Type':'application/x-www-form-urlencoded'}});const result=await response.json();showMessage(result.message||'连接失败，请重试。',!result.success);if(result.success){submit.textContent='已保存到电视';return;}}catch(error){showMessage('无法连接 Apple TV，请检查同一 Wi‑Fi 并重新扫码。',true);}submit.disabled=false;submit.textContent='重新测试连接';}
        kind.addEventListener('change',updateKind);form.addEventListener('submit',sendForm);updateKind();
        </script></body></html>
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

    /// 将电视端真实连接结果返回手机，失败时保留用户已填写的表单。
    private func sendJSON(success: Bool, message: String, connection: NWConnection) {
        let value: [String: Any] = ["success": success, "message": message]
        let body = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
        let header = "HTTP/1.1 \(success ? "200 OK" : "422 Unprocessable Content")\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
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
    private var isConnecting = false
    private var server: TVPairingHTTPServer?

    /// 启动一次新的随机令牌配对会话。
    func start() {
        guard server == nil else { return }
        do {
            let value = try TVPairingHTTPServer { [weak self] payload in
                await self?.connect(payload) ?? (false, "配对已结束，请重新扫码。")
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
    private func connect(_ payload: TVMediaSourcePairingPayload) async -> (Bool, String) {
        guard savedProfile == nil else { return (false, "当前配对已完成，请在电视上重新打开手机配置。") }
        guard !isConnecting else { return (false, "电视正在测试上一份配置，请稍后再试。") }
        guard let url = payload.serverURL() else {
            statusText = "服务器地址无效，请在手机上检查后重新提交"
            return (false, statusText)
        }
        isConnecting = true
        defer { isConnecting = false }
        statusText = "正在测试 \(payload.kind.title) 连接…"
        do {
            let secret: MediaSourceSecret
            switch payload.kind {
            case .webDAV:
                let root = payload.rootPath.isEmpty ? "/" : payload.rootPath
                let start = webDAVDirectoryURL(server: url, rootPath: root)
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
            return (true, statusText)
        } catch {
            let detail = error is URLError ? "无法连接服务器，请检查地址、端口和网络。" : error.localizedDescription
            statusText = "连接失败：\(detail)"
            return (false, statusText)
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
