import Foundation

/// 朗读引擎类型。默认 Edge(免 key 的微软神经语音),可切 Azure(自带 key),或系统语音(离线兜底)。
enum TTSEngineKind: String, CaseIterable, Identifiable, Sendable {
    case edge      // 微软 Edge「大声朗读」端点,免 key、神经语音
    case azure     // Azure 官方 TTS,需自带 key + region
    case system    // 系统 AVSpeechSynthesizer,离线兜底

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .edge:   return "Edge 神经语音(免 key)"
        case .azure:  return "Azure 官方(自带 key)"
        case .system: return "系统语音(离线)"
        }
    }

    var detail: String {
        switch self {
        case .edge:   return "微软 Edge「大声朗读」同款神经语音,免注册免费,需联网。非官方端点,失效时自动回退系统语音。"
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

    /// Azure key 存进 KeychainStore,用一个固定命名空间 UUID 作 id(与 provider 的 id 不冲突)。
    static let azureKeyID = UUID(uuidString: "7A5C0DE0-0000-4000-A000-000000000A2E")!

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
