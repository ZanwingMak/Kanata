import Foundation

/// OpenSubtitles 返回的一条可下载在线字幕候选。
struct OnlineSubtitleCandidate: Identifiable, Hashable, Sendable {
    let fileID: Int
    let fileName: String
    let language: String
    let title: String
    let releaseName: String?
    let season: Int?
    let episode: Int?
    let downloadCount: Int
    let rating: Double
    let isTrusted: Bool
    let isHearingImpaired: Bool
    let isMachineTranslated: Bool

    var id: Int { fileID }

    /// 返回适合候选列表主标题的作品与集数信息。
    var displayTitle: String {
        guard let episode else { return title }
        if let season { return "\(title) · S\(season)E\(episode)" }
        return "\(title) · 第 \(episode) 集"
    }
}

/// 已从在线字幕服务下载的文件内容。
struct DownloadedOnlineSubtitle: Sendable {
    let data: Data
    let fileName: String
}

/// OpenSubtitles REST API 客户端，只使用用户自行配置的 API Key。
actor OpenSubtitlesClient {
    private let apiKey: String
    private let session: URLSession
    private let baseURL = URL(string: "https://api.opensubtitles.com/api/v1")!

    /// 创建带短超时和无持久 Cookie 的在线字幕客户端。
    /// - Parameter apiKey: 用户在 OpenSubtitles 申请的 API Key。
    init(apiKey: String) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        self.session = URLSession(configuration: configuration)
    }

    /// 按作品名和可选季集信息搜索在线字幕，并优先返回设备语言。
    /// - Parameters:
    ///   - query: 作品名或媒体文件名。
    ///   - season: 可选季度。
    ///   - episode: 可选集数。
    /// - Returns: 已按集数、语言和质量排序的字幕候选。
    func search(query: String, season: Int?, episode: Int?) async throws -> [OnlineSubtitleCandidate] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !keyword.isEmpty else { throw OpenSubtitlesError.missingConfiguration }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("subtitles"),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [
            URLQueryItem(name: "languages", value: ExternalSubtitlePreference.preferredOnlineLanguageCodes().sorted().joined(separator: ",")),
            URLQueryItem(name: "machine_translated", value: "exclude"),
            URLQueryItem(name: "query", value: keyword.lowercased()),
        ]
        if let episode {
            queryItems.append(URLQueryItem(name: "episode_number", value: String(episode)))
            queryItems.append(URLQueryItem(name: "type", value: "episode"))
        }
        if let season {
            queryItems.append(URLQueryItem(name: "season_number", value: String(season)))
        }
        components?.queryItems = queryItems.sorted { $0.name < $1.name }
        guard let url = components?.url else { throw OpenSubtitlesError.invalidResponse }
        let data = try await requestData(url: url)
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        let candidates = response.data.compactMap(Self.makeCandidate)
        return Self.sorted(candidates, season: season, episode: episode)
    }

    /// 为指定候选申请短期下载地址，并返回统一为 SRT 的字幕数据。
    /// - Parameter candidate: 用户选择的在线字幕候选。
    /// - Returns: 可交给现有外挂字幕解析器的数据与文件名。
    func download(_ candidate: OnlineSubtitleCandidate) async throws -> DownloadedOnlineSubtitle {
        var request = authorizedRequest(url: baseURL.appendingPathComponent("download"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(DownloadRequest(fileID: candidate.fileID, subtitleFormat: "srt"))
        let responseData = try await perform(request)
        let response = try JSONDecoder().decode(DownloadResponse.self, from: responseData)
        guard let url = URL(string: response.link) else { throw OpenSubtitlesError.invalidResponse }
        let (data, urlResponse) = try await session.data(from: url)
        try Self.validate(urlResponse, data: data)
        guard data.count <= 12 * 1_024 * 1_024 else { throw OpenSubtitlesError.fileTooLarge }
        let downloadedName = response.fileName ?? candidate.fileName
        let rawName = downloadedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = rawName.isEmpty ? "subtitle-\(candidate.fileID)" : rawName
        let fileName = URL(fileURLWithPath: safeName).pathExtension.isEmpty ? "\(safeName).srt" : safeName
        return DownloadedOnlineSubtitle(data: data, fileName: fileName)
    }

    /// 发送带 API Key 的 GET 请求并返回响应数据。
    /// - Parameter url: OpenSubtitles API 地址。
    /// - Returns: 校验成功的响应体。
    private func requestData(url: URL) async throws -> Data {
        try await perform(authorizedRequest(url: url))
    }

    /// 创建不会暴露密钥到 URL 的授权请求。
    /// - Parameter url: API 请求地址。
    /// - Returns: 已添加必要请求头的 URLRequest。
    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("Kanata v\(Self.appVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// 执行 API 请求并统一处理 HTTP 错误信息。
    /// - Parameter request: 已完成配置的请求。
    /// - Returns: 成功响应体。
    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
        return data
    }

    /// 校验网络响应，并尽量保留服务端返回的可读错误。
    /// - Parameters:
    ///   - response: URLSession 响应。
    ///   - data: 服务端响应体。
    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw OpenSubtitlesError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.message
            if http.statusCode == 401 || http.statusCode == 403 {
                throw OpenSubtitlesError.authenticationFailed(message)
            }
            throw OpenSubtitlesError.http(http.statusCode, message)
        }
    }

    /// 将 API 响应节点转换为播放器使用的精简候选。
    /// - Parameter item: OpenSubtitles 搜索响应节点。
    /// - Returns: 响应包含可下载文件时返回候选。
    private static func makeCandidate(_ item: SearchItem) -> OnlineSubtitleCandidate? {
        guard let file = item.attributes.files.first else { return nil }
        let feature = item.attributes.featureDetails
        let title = feature.parentTitle ?? feature.movieName ?? feature.title ?? item.attributes.release ?? file.fileName
        return OnlineSubtitleCandidate(
            fileID: file.fileID,
            fileName: file.fileName,
            language: item.attributes.language,
            title: title,
            releaseName: item.attributes.release,
            season: feature.seasonNumber,
            episode: feature.episodeNumber,
            downloadCount: item.attributes.downloadCount ?? 0,
            rating: item.attributes.rating ?? 0,
            isTrusted: item.attributes.isTrusted ?? false,
            isHearingImpaired: item.attributes.isHearingImpaired ?? false,
            isMachineTranslated: item.attributes.isMachineTranslated ?? false
        )
    }

    /// 按季集完全匹配、设备语言、可信度和下载量稳定排序。
    /// - Parameters:
    ///   - values: 未排序候选。
    ///   - season: 当前视频季度。
    ///   - episode: 当前视频集数。
    /// - Returns: 最可能适配当前视频的候选排在前面。
    private static func sorted(
        _ values: [OnlineSubtitleCandidate],
        season: Int?,
        episode: Int?
    ) -> [OnlineSubtitleCandidate] {
        values.sorted { left, right in
            let leftEpisodeRank = episodeRank(left, season: season, episode: episode)
            let rightEpisodeRank = episodeRank(right, season: season, episode: episode)
            if leftEpisodeRank != rightEpisodeRank { return leftEpisodeRank < rightEpisodeRank }
            let leftLanguage = ExternalSubtitlePreference.languageRank(fileName: left.language)
            let rightLanguage = ExternalSubtitlePreference.languageRank(fileName: right.language)
            if leftLanguage != rightLanguage { return leftLanguage < rightLanguage }
            if left.isTrusted != right.isTrusted { return left.isTrusted }
            if left.rating != right.rating { return left.rating > right.rating }
            if left.downloadCount != right.downloadCount { return left.downloadCount > right.downloadCount }
            return left.fileName.localizedStandardCompare(right.fileName) == .orderedAscending
        }
    }

    /// 返回候选季集与当前视频的匹配等级。
    /// - Parameters:
    ///   - candidate: 在线字幕候选。
    ///   - season: 当前季度。
    ///   - episode: 当前集数。
    /// - Returns: 完全匹配为 0，缺少元数据为 1，不匹配为 2。
    private static func episodeRank(_ candidate: OnlineSubtitleCandidate, season: Int?, episode: Int?) -> Int {
        guard let episode else { return 0 }
        guard let candidateEpisode = candidate.episode else { return 1 }
        guard candidateEpisode == episode else { return 2 }
        guard let season else { return 0 }
        guard let candidateSeason = candidate.season else { return 1 }
        return candidateSeason == season ? 0 : 2
    }

    /// 返回 User-Agent 使用的当前 App 市场版本。
    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }
}

/// OpenSubtitles 在线搜索与下载错误。
enum OpenSubtitlesError: LocalizedError {
    case missingConfiguration
    case invalidResponse
    case authenticationFailed(String?)
    case http(Int, String?)
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .missingConfiguration: "请先在设置中填写 OpenSubtitles API Key"
        case .invalidResponse: "在线字幕服务返回了无法识别的数据"
        case .authenticationFailed(let message): message ?? "OpenSubtitles API Key 无效或没有下载权限"
        case .http(let statusCode, let message): message ?? "在线字幕请求失败（HTTP \(statusCode)）"
        case .fileTooLarge: "字幕文件超过 12 MB，已停止加载"
        }
    }
}

private extension OpenSubtitlesClient {
    struct SearchResponse: Decodable {
        let data: [SearchItem]
    }

    struct SearchItem: Decodable {
        let attributes: Attributes
    }

    struct Attributes: Decodable {
        let language: String
        let downloadCount: Int?
        let isHearingImpaired: Bool?
        let rating: Double?
        let isTrusted: Bool?
        let isMachineTranslated: Bool?
        let release: String?
        let featureDetails: FeatureDetails
        let files: [SubtitleFile]

        enum CodingKeys: String, CodingKey {
            case language
            case downloadCount = "download_count"
            case isHearingImpaired = "hearing_impaired"
            case rating = "ratings"
            case isTrusted = "from_trusted"
            case isMachineTranslated = "machine_translated"
            case release
            case featureDetails = "feature_details"
            case files
        }
    }

    struct FeatureDetails: Decodable {
        let title: String?
        let movieName: String?
        let parentTitle: String?
        let seasonNumber: Int?
        let episodeNumber: Int?

        enum CodingKeys: String, CodingKey {
            case title
            case movieName = "movie_name"
            case parentTitle = "parent_title"
            case seasonNumber = "season_number"
            case episodeNumber = "episode_number"
        }
    }

    struct SubtitleFile: Decodable {
        let fileID: Int
        let fileName: String

        enum CodingKeys: String, CodingKey {
            case fileID = "file_id"
            case fileName = "file_name"
        }
    }

    struct DownloadRequest: Encodable {
        let fileID: Int
        let subtitleFormat: String

        enum CodingKeys: String, CodingKey {
            case fileID = "file_id"
            case subtitleFormat = "sub_format"
        }
    }

    struct DownloadResponse: Decodable {
        let link: String
        let fileName: String?

        enum CodingKeys: String, CodingKey {
            case link
            case fileName = "file_name"
        }
    }

    struct ErrorResponse: Decodable {
        let message: String?
    }
}
