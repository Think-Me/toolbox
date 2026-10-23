import Foundation

/// 翻译引擎。
public enum TranslationEngine: String, Codable, CaseIterable, Sendable {
    /// 自动：Apple 本地可用就本地，否则用有道（国内可直连）。
    case auto
    case apple
    case youdao
    case mymemory
    case google
    case ai

    public var label: String {
        switch self {
        case .auto:     return "自动（优先本地）"
        case .apple:    return "Apple 本地"
        case .youdao:   return "有道（免费）"
        case .mymemory: return "MyMemory（免费）"
        case .google:   return "Google（需代理）"
        case .ai:       return "AI（需 Key）"
        }
    }

    /// 需要联网的引擎（Apple 本地不联网）。
    public var isOnline: Bool { self != .apple && self != .auto }
}

/// 在线引擎的网络方式。
public enum TranslationNetwork: String, Codable, CaseIterable, Sendable {
    case auto
    case direct
    case proxy

    public var label: String {
        switch self {
        case .auto:   return "自动（按引擎）"
        case .direct: return "直连"
        case .proxy:  return "走代理"
        }
    }
}

/// 划词翻译设置。和 `UpdateSettings` 一样：所有字段都有默认值，
/// `init(from:)` 用 `decodeIfPresent`，老 settings.json 缺字段不会整份解码失败。
public struct TranslationSettings: Codable, Equatable, Sendable {
    public var engine: TranslationEngine
    /// 目标语言用 BCP-47（如 zh-Hans / en / ja）
    public var targetLanguage: String
    public var network: TranslationNetwork
    public var proxyPort: Int
    /// OpenAI 兼容接口（DeepSeek / 通义 / OpenAI…）
    public var aiBaseURL: String
    public var aiModel: String

    public init(engine: TranslationEngine = .auto,
                targetLanguage: String = "zh-Hans",
                network: TranslationNetwork = .auto,
                proxyPort: Int = 10809,
                aiBaseURL: String = "https://api.deepseek.com/v1",
                aiModel: String = "deepseek-chat") {
        self.engine = engine
        self.targetLanguage = targetLanguage
        self.network = network
        self.proxyPort = proxyPort
        self.aiBaseURL = aiBaseURL
        self.aiModel = aiModel
    }

    private enum CodingKeys: String, CodingKey {
        case engine, targetLanguage, network, proxyPort, aiBaseURL, aiModel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = ((try? c.decodeIfPresent(TranslationEngine.self, forKey: .engine)) ?? nil) ?? .auto
        targetLanguage = try c.decodeIfPresent(String.self, forKey: .targetLanguage) ?? "zh-Hans"
        network = ((try? c.decodeIfPresent(TranslationNetwork.self, forKey: .network)) ?? nil) ?? .auto
        proxyPort = try c.decodeIfPresent(Int.self, forKey: .proxyPort) ?? 10809
        aiBaseURL = try c.decodeIfPresent(String.self, forKey: .aiBaseURL) ?? "https://api.deepseek.com/v1"
        aiModel = try c.decodeIfPresent(String.self, forKey: .aiModel) ?? "deepseek-chat"
    }
}
