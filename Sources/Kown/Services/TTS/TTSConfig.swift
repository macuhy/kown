import Foundation

/// 朗读引擎类型。默认 Edge(免 key 的微软神经语音),可切 Azure(自带 key),或系统语音(离线兜底)。
enum TTSEngineKind: String, CaseIterable, Identifiable, Sendable {
    case siliconflow // 硅基流动 CosyVoice2,OpenAI 兼容,国内直连
    case edge        // 微软 Edge「大声朗读」端点,免 key、神经语音
    case azure       // Azure 官方 TTS,需自带 key + region
    case system      // 系统 AVSpeechSynthesizer,离线兜底

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .siliconflow: return "硅基流动 CosyVoice(国内)"
        case .edge:   return "Edge 神经语音(免 key)"
        case .azure:  return "Azure 官方(自带 key)"
        case .system: return "系统语音(离线)"
        }
    }

    var detail: String {
        switch self {
        case .siliconflow: return "硅基流动 CosyVoice2,OpenAI 兼容、国内直连,音色自然、支持方言。需在设置里填 SiliconFlow Key(注册送额度)。"
        case .edge:   return "微软 Edge「大声朗读」同款神经语音,免注册免费,需联网。非官方端点,部分网络会被拦截,失效时自动回退系统语音。"
        case .azure:  return "Azure 认知服务 TTS,神经语音,免费层每月 50 万字符。需在设置里填 Key 和 Region。"
        case .system: return "系统内置语音合成,离线可用,音色较生硬。"
        }
    }

    /// 是否依赖网络。
    var isNetwork: Bool { self != .system }
}

/// 一个可选的神经语音。
struct TTSVoice: Identifiable, Hashable, Sendable {
    let id: String       // 如 "zh-CN-XiaoxiaoNeural"
    let label: String    // 如 "晓晓 · 女声(温柔)"
}

/// 朗读相关的持久化配置(UserDefaults + Keychain)。
@MainActor
enum TTSConfig {
    private static let engineKey = "kown.tts.engine.v1"
    private static let voiceKey  = "kown.tts.voice.v1"
    private static let azureRegionKey = "kown.tts.azure.region.v1"
    private static let azureRateKey   = "kown.tts.rate.v1"
    private static let sfVoiceKey = "kown.tts.sf.voice.v1"
    private static let sfModelKey = "kown.tts.sf.model.v1"
    private static let sfBaseURLKey = "kown.tts.sf.baseURL.v1"

    /// Azure key 存进 KeychainStore,用一个固定命名空间 UUID 作 id(与 provider 的 id 不冲突)。
    static let azureKeyID = UUID(uuidString: "7A5C0DE0-0000-4000-A000-000000000A2E")!
    /// 硅基流动 key 的 Keychain id。
    static let siliconflowKeyID = UUID(uuidString: "7A5C0DE0-0000-4000-A000-000000000A2F")!

    /// CosyVoice2 预置音色(存短名,请求时拼成 `model:name`)。
    static let siliconflowVoices: [TTSVoice] = [
        TTSVoice(id: "alex",     label: "Alex · 男声(沉稳)"),
        TTSVoice(id: "benjamin", label: "Benjamin · 男声(磁性)"),
        TTSVoice(id: "charles",  label: "Charles · 男声(浑厚)"),
        TTSVoice(id: "david",    label: "David · 男声(活力)"),
        TTSVoice(id: "anna",     label: "Anna · 女声(亲切)"),
        TTSVoice(id: "bella",    label: "Bella · 女声(温柔)"),
        TTSVoice(id: "claire",   label: "Claire · 女声(知性)"),
        TTSVoice(id: "diana",    label: "Diana · 女声(甜美)"),
    ]
    static let siliconflowDefaultModel = "FunAudioLLM/CosyVoice2-0.5B"
    static let siliconflowDefaultBaseURL = "https://api.siliconflow.cn/v1"

    /// 常用中文神经语音(Edge / Azure 共用同一套 voice 名)。
    static let voices: [TTSVoice] = [
        TTSVoice(id: "zh-CN-XiaoxiaoNeural",  label: "晓晓 · 女声(温柔)"),
        TTSVoice(id: "zh-CN-XiaoyiNeural",    label: "晓伊 · 女声(亲切)"),
        TTSVoice(id: "zh-CN-YunxiNeural",     label: "云希 · 男声(阳光)"),
        TTSVoice(id: "zh-CN-YunjianNeural",   label: "云健 · 男声(沉稳)"),
        TTSVoice(id: "zh-CN-YunyangNeural",   label: "云扬 · 男声(播音)"),
        TTSVoice(id: "zh-CN-YunxiaNeural",    label: "云夏 · 男声(少年)"),
        TTSVoice(id: "zh-CN-liaoning-XiaobeiNeural", label: "晓北 · 女声(东北)"),
        TTSVoice(id: "en-US-AriaNeural",      label: "Aria · 英语女声"),
        TTSVoice(id: "en-US-GuyNeural",       label: "Guy · 英语男声"),
    ]

    static let defaultVoice = "zh-CN-XiaoxiaoNeural"

    static var engine: TTSEngineKind {
        get {
            let raw = UserDefaults.standard.string(forKey: engineKey)
            return raw.flatMap(TTSEngineKind.init(rawValue:)) ?? .edge
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: engineKey) }
    }

    static var voice: String {
        get { UserDefaults.standard.string(forKey: voiceKey) ?? defaultVoice }
        set { UserDefaults.standard.set(newValue, forKey: voiceKey) }
    }

    static var azureRegion: String {
        get { UserDefaults.standard.string(forKey: azureRegionKey) ?? "eastasia" }
        set { UserDefaults.standard.set(newValue, forKey: azureRegionKey) }
    }

    /// 语速百分比偏移(-50 ~ +50),SSML 的 prosody rate。默认 0。
    static var ratePercent: Int {
        get {
            let v = UserDefaults.standard.object(forKey: azureRateKey) as? Int
            return v ?? 0
        }
        set { UserDefaults.standard.set(newValue, forKey: azureRateKey) }
    }

    static var azureKey: String? {
        try? KeychainStore.load(id: azureKeyID)
    }

    // MARK: - 硅基流动

    static var siliconflowKey: String? {
        try? KeychainStore.load(id: siliconflowKeyID)
    }
    static var siliconflowVoice: String {
        get { UserDefaults.standard.string(forKey: sfVoiceKey) ?? "alex" }
        set { UserDefaults.standard.set(newValue, forKey: sfVoiceKey) }
    }
    static var siliconflowModel: String {
        get {
            let v = UserDefaults.standard.string(forKey: sfModelKey) ?? ""
            return v.isEmpty ? siliconflowDefaultModel : v
        }
        set { UserDefaults.standard.set(newValue, forKey: sfModelKey) }
    }
    static var siliconflowBaseURL: String {
        get {
            let v = UserDefaults.standard.string(forKey: sfBaseURLKey) ?? ""
            return v.isEmpty ? siliconflowDefaultBaseURL : v
        }
        set { UserDefaults.standard.set(newValue, forKey: sfBaseURLKey) }
    }

    // MARK: - 按引擎取音色(不同引擎音色名空间不同)

    static func voices(for engine: TTSEngineKind) -> [TTSVoice] {
        engine == .siliconflow ? siliconflowVoices : voices
    }
    static func voice(for engine: TTSEngineKind) -> String {
        engine == .siliconflow ? siliconflowVoice : voice
    }
    static func setVoice(_ v: String, for engine: TTSEngineKind) {
        if engine == .siliconflow { siliconflowVoice = v } else { voice = v }
    }

    static func voiceLabel(for id: String) -> String {
        voices.first(where: { $0.id == id })?.label ?? id
    }
}

enum TTSError: Error, LocalizedError {
    case network(String)
    case empty
    case notConfigured(String)

    var errorDescription: String? {
        switch self {
        case .network(let m):       return "语音合成失败: \(m)"
        case .empty:                return "语音合成返回空音频"
        case .notConfigured(let m): return m
        }
    }
}
