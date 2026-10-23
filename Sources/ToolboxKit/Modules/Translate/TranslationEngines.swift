import Foundation

public struct TranslationOutput: Sendable, Equatable {
    public var text: String
    public var detectedLanguage: String?
    public var engine: TranslationEngine

    public init(text: String, detectedLanguage: String?, engine: TranslationEngine) {
        self.text = text
        self.detectedLanguage = detectedLanguage
        self.engine = engine
    }
}

public enum TranslationError: LocalizedError, Equatable, Sendable {
    case emptyInput
    case missingKey
    case http(Int)
    case rejected(String)
    case malformed
    case appleUnavailable
    case unsupportedPair
    case network(String)
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput:        return "没有可翻译的文本"
        case .missingKey:        return "AI 引擎还没填 API Key（设置 › 翻译）"
        case .http(let code):    return "接口返回 HTTP \(code)"
        case .rejected(let m):   return "接口拒绝：\(m)"
        case .malformed:         return "接口返回了无法解析的数据"
        case .appleUnavailable:  return "Apple 本地翻译不可用（需 macOS 15+ 且已安装语言包）"
        case .unsupportedPair:   return "Apple 本地不支持这组语言，换一个引擎试试"
        case .network(let m):    return "网络错误：\(m)"
        case .message(let m):    return m
        }
    }
}

public protocol Translator: Sendable {
    var label: String { get }
    /// source 为 nil 表示让引擎自动识别
    func translate(_ text: String, from source: String?, to target: String) async throws -> TranslationOutput
}

/// 代理策略：auto 只给"需要翻墙"的域名套代理，国内可直连的走直连。
/// 这是实测结论（见 docs 里的接口探测）：有道/MyMemory 直连可用，Google 直连会被拦。
public enum TranslationNetworkPolicy {
    static let directHosts = [
        "youdao.com", "mymemory.translated.net",
        "api.deepseek.com", "dashscope.aliyuncs.com",
        "open.bigmodel.cn", "api.moonshot.cn", "api.siliconflow.cn",
    ]

    public static func proxyPort(for host: String, settings: TranslationSettings) -> Int? {
        switch settings.network {
        case .direct:
            return nil
        case .proxy:
            return settings.proxyPort
        case .auto:
            return directHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) })
                ? nil : settings.proxyPort
        }
    }
}

public enum TranslatorFactory {
    public static func make(engine: TranslationEngine,
                            settings: TranslationSettings,
                            aiKey: String?) -> (any Translator)? {
        switch engine {
        case .auto, .apple:
            return nil
        case .youdao:
            return YoudaoTranslator(fetcher: fetcher(for: "aidemo.youdao.com", settings: settings))
        case .mymemory:
            return MyMemoryTranslator(fetcher: fetcher(for: "api.mymemory.translated.net", settings: settings))
        case .google:
            return GoogleTranslator(fetcher: fetcher(for: "translate.googleapis.com", settings: settings))
        case .ai:
            return AITranslator(fetcher: fetcher(for: host(of: settings.aiBaseURL), settings: settings),
                                baseURL: settings.aiBaseURL,
                                model: settings.aiModel,
                                apiKey: aiKey)
        }
    }

    static func fetcher(for host: String, settings: TranslationSettings) -> URLSessionFetcher {
        URLSessionFetcher(proxyPort: TranslationNetworkPolicy.proxyPort(for: host, settings: settings))
    }

    static func host(of urlString: String) -> String {
        URL(string: urlString)?.host ?? urlString
    }
}

// MARK: - 有道

/// `aidemo.youdao.com/trans`：表单 POST，支持 from=auto。
public struct YoudaoTranslator: Translator {
    let fetcher: any HTTPFetching & HTTPPosting
    public let label = "有道"

    public init(fetcher: any HTTPFetching & HTTPPosting) { self.fetcher = fetcher }

    public func translate(_ text: String, from source: String?, to target: String) async throws -> TranslationOutput {
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "from", value: source.map(TranslationLanguages.youdaoCode(for:)) ?? "auto"),
            URLQueryItem(name: "to", value: TranslationLanguages.youdaoCode(for: target)),
        ]
        guard let url = URL(string: "https://aidemo.youdao.com/trans") else { throw TranslationError.malformed }
        let data = try await fetcher.post(
            url, contentType: "application/x-www-form-urlencoded",
            body: Data((body.percentEncodedQuery ?? "").utf8),
            headers: ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"])

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslationError.malformed
        }
        if let code = obj["errorCode"] as? Int, code != 0 {
            throw TranslationError.rejected("错误码 \(code)")
        }
        guard let parts = obj["translation"] as? [String], !parts.isEmpty else {
            throw TranslationError.malformed
        }
        // "l" 形如 en2zh-CHS，能直接回报检测到的源语言
        var detected: String?
        if let pair = obj["l"] as? String, let src = pair.components(separatedBy: "2").first {
            detected = src.isEmpty ? nil : src
        }
        return TranslationOutput(text: parts.joined(), detectedLanguage: detected, engine: .youdao)
    }
}

// MARK: - MyMemory

/// 免费、直连可用，但没有 auto，源语言只能本地猜。
public struct MyMemoryTranslator: Translator {
    let fetcher: any HTTPFetching & HTTPPosting
    public let label = "MyMemory"

    public init(fetcher: any HTTPFetching & HTTPPosting) { self.fetcher = fetcher }

    public func translate(_ text: String, from source: String?, to target: String) async throws -> TranslationOutput {
        let src = source.map(TranslationLanguages.webCode(for:))
            ?? TranslationLanguages.webCode(for: TranslationLanguages.guessSource(text))
        var comps = URLComponents(string: "https://api.mymemory.translated.net/get")
        comps?.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "langpair", value: "\(src)|\(TranslationLanguages.webCode(for: target))"),
        ]
        guard let url = comps?.url else { throw TranslationError.malformed }
        let data = try await fetcher.get(url)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = obj["responseData"] as? [String: Any],
              let translated = response["translatedText"] as? String
        else { throw TranslationError.malformed }
        if let status = obj["responseStatus"] as? Int, status != 200 {
            throw TranslationError.rejected((obj["responseDetails"] as? String) ?? "状态 \(status)")
        }
        return TranslationOutput(text: decodedEntities(translated), detectedLanguage: src, engine: .mymemory)
    }

    /// MyMemory 会把 `&` 之类转成实体，先还原再做界面展示。
    /// 不走 NSAttributedString 的 HTML 解析：为几个实体拉一次 WebKit 式解析太重。
    private func decodedEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - Google

/// gtx 免费端点。国内必须走代理，且可能被反爬页拦（会返回 HTML 而不是 JSON）。
public struct GoogleTranslator: Translator {
    let fetcher: any HTTPFetching & HTTPPosting
    public let label = "Google"

    public init(fetcher: any HTTPFetching & HTTPPosting) { self.fetcher = fetcher }

    public func translate(_ text: String, from source: String?, to target: String) async throws -> TranslationOutput {
        var comps = URLComponents(string: "https://translate.googleapis.com/translate_a/single")
        comps?.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: source.map(TranslationLanguages.webCode(for:)) ?? "auto"),
            URLQueryItem(name: "tl", value: TranslationLanguages.webCode(for: target)),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text),
        ]
        guard let url = comps?.url else { throw TranslationError.malformed }
        let data = try await fetcher.get(url)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = root.first as? [[Any]] else {
            throw TranslationError.message("Google 接口被拦截（返回的不是 JSON）。国内请配置代理或改用其他引擎。")
        }
        let text = segments.compactMap { $0.first as? String }.joined()
        guard !text.isEmpty else { throw TranslationError.malformed }
        let detected = root.count > 2 ? root[2] as? String : nil
        return TranslationOutput(text: text, detectedLanguage: detected, engine: .google)
    }
}

// MARK: - AI（OpenAI 兼容）

public struct AITranslator: Translator {
    let fetcher: any HTTPFetching & HTTPPosting
    let baseURL: String
    let model: String
    let apiKey: String?
    public let label = "AI"

    public init(fetcher: any HTTPFetching & HTTPPosting, baseURL: String, model: String, apiKey: String?) {
        self.fetcher = fetcher
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    public func translate(_ text: String, from source: String?, to target: String) async throws -> TranslationOutput {
        guard let apiKey, !apiKey.isEmpty else { throw TranslationError.missingKey }
        let base = baseURL.hasSuffix("/") ? baseURL : baseURL + "/"
        guard let url = URL(string: base + "chat/completions") else { throw TranslationError.malformed }

        let targetName = TranslationLanguages.label(for: target)
        let system = "You are a professional translation engine. Translate into \(targetName). "
            + "Preserve formatting, names and code. Output only the translation, no explanations."
        let payload: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": text],
            ],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw TranslationError.malformed
        }
        let data = try await fetcher.post(
            url, contentType: "application/json", body: body,
            headers: ["Authorization": "Bearer \(apiKey)"])

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslationError.malformed
        }
        if let error = obj["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw TranslationError.rejected(message)
        }
        guard let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranslationError.malformed
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslationError.malformed }
        return TranslationOutput(text: trimmed, detectedLanguage: source, engine: .ai)
    }
}
