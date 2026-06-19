import Foundation

/// 朗读引擎类型。默认 Edge(免 key 的微软神经语音),可切 Azure(自带 key),或系统语音(离线兜底)。
enum TTSEngineKind: String, CaseIterable, Identifiable, Sendable {
    case siliconflow // 硅基流动 CosyVoice2,OpenAI 兼容,国内直连
    case xunfei      // 讯飞在线语音合成,WebSocket,国内直连
    case system      // 系统 AVSpeechSynthesizer,离线兜底

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .siliconflow: return "硅基流动 CosyVoice(国内)"
        case .xunfei: return "讯飞语音(国内)"
        case .system: return "系统语音(离线)"
        }
    }

    var detail: String {
        switch self {
        case .siliconflow: return "硅基流动 CosyVoice2,OpenAI 兼容、国内直连,音色自然、支持方言。需在设置里填 SiliconFlow Key(注册送额度)。"
        case .xunfei: return "科大讯飞在线语音合成,国内直连、老牌成熟、发音人丰富(每日 500 次免费)。需填 APPID / APIKey / APISecret(讯飞开放平台)。"
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

/// 朗读相关的持久化配置(UserDefaults + KeychainStore secret store)。
@MainActor
enum TTSConfig {
    private static let engineKey = "kown.tts.engine.v1"
    private static let voiceKey  = "kown.tts.voice.v1"
    private static let azureRateKey   = "kown.tts.rate.v1"
    private static let sfVoiceKey = "kown.tts.sf.voice.v1"
    private static let sfModelKey = "kown.tts.sf.model.v1"
    private static let sfBaseURLKey = "kown.tts.sf.baseURL.v1"
    private static let xfAppIDKey = "kown.tts.xf.appid.v1"
    private static let xfVoiceKey = "kown.tts.xf.voice.v1"

    /// 硅基流动 key 的 secret-store id。
    static let siliconflowKeyID = UUID(uuidString: "7A5C0DE0-0000-4000-A000-000000000A2F")!
    /// 讯飞 APIKey / APISecret 的 secret-store id(APPID 不算密钥,存 UserDefaults)。
    static let xunfeiAPIKeyID = UUID(uuidString: "7A5C0DE0-0000-4000-A000-000000000A30")!
    static let xunfeiAPISecretID = UUID(uuidString: "7A5C0DE0-0000-4000-A000-000000000A31")!

    /// 讯飞常用发音人(部分需在控制台开通/购买;xiaoyan 为默认免费)。
    static let xunfeiVoices: [TTSVoice] = [
        TTSVoice(id: "x4_yezi",    label: "叶子 · 女声(超拟人,需开通)"),
        TTSVoice(id: "xiaoyan",    label: "讯飞小燕 · 女声(默认免费)"),
        TTSVoice(id: "aisjiuxu",   label: "许久 · 男声"),
        TTSVoice(id: "aisxping",   label: "小萍 · 女声"),
        TTSVoice(id: "aisjinger",  label: "婧儿 · 女声"),
        TTSVoice(id: "aisbabyxu",  label: "许小宝 · 童声"),
    ]

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

    // MARK: - 偏好持久化(放同步目录 tts.json → 随 iCloud 同步;密钥另走本地-only secret store)

    private struct Prefs: Codable {
        var engine, voice, sfVoice, sfModel, sfBaseURL, xfAppID, xfVoice: String?
        var ratePercent: Int?
    }
    private static var prefsURL: URL {
        Platform.syncedDataDir.appendingPathComponent("tts.json")
    }
    private static func loadPrefs() -> Prefs {
        if let d = try? Data(contentsOf: prefsURL), let p = try? JSONDecoder().decode(Prefs.self, from: d) {
            return p
        }
        // 首次:把旧版本存在 UserDefaults.standard 的设置迁移进同步文件
        let ud = UserDefaults.standard
        var p = Prefs()
        p.engine = ud.string(forKey: engineKey)
        p.voice = ud.string(forKey: voiceKey)
        if ud.object(forKey: azureRateKey) != nil { p.ratePercent = ud.integer(forKey: azureRateKey) }
        p.sfVoice = ud.string(forKey: sfVoiceKey)
        p.sfModel = ud.string(forKey: sfModelKey)
        p.sfBaseURL = ud.string(forKey: sfBaseURLKey)
        p.xfAppID = ud.string(forKey: xfAppIDKey)
        p.xfVoice = ud.string(forKey: xfVoiceKey)
        if p.engine != nil || p.voice != nil { savePrefs(p) }  // 有旧值才落盘,避免给新装用户建空文件
        return p
    }
    private static func savePrefs(_ p: Prefs) {
        try? FileManager.default.createDirectory(at: Platform.syncedDataDir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(p) { try? d.write(to: prefsURL, options: .atomic) }
    }
    private static func update(_ mutate: (inout Prefs) -> Void) {
        var p = loadPrefs(); mutate(&p); savePrefs(p)
    }

    static var engine: TTSEngineKind {
        get { loadPrefs().engine.flatMap(TTSEngineKind.init(rawValue:)) ?? .siliconflow }
        set { update { $0.engine = newValue.rawValue } }
    }

    static var voice: String {
        get { loadPrefs().voice ?? defaultVoice }
        set { update { $0.voice = newValue } }
    }

    /// 语速百分比偏移(-50 ~ +50),SSML 的 prosody rate。默认 0。
    static var ratePercent: Int {
        get { loadPrefs().ratePercent ?? 0 }
        set { update { $0.ratePercent = newValue } }
    }

    // MARK: - 硅基流动

    static var siliconflowKey: String? {
        try? KeychainStore.load(id: siliconflowKeyID)
    }
    static var siliconflowVoice: String {
        get { loadPrefs().sfVoice ?? "alex" }
        set { update { $0.sfVoice = newValue } }
    }
    static var siliconflowModel: String {
        get { let v = loadPrefs().sfModel ?? ""; return v.isEmpty ? siliconflowDefaultModel : v }
        set { update { $0.sfModel = newValue } }
    }
    static var siliconflowBaseURL: String {
        get { let v = loadPrefs().sfBaseURL ?? ""; return v.isEmpty ? siliconflowDefaultBaseURL : v }
        set { update { $0.sfBaseURL = newValue } }
    }

    // MARK: - 讯飞

    static var xunfeiAppID: String {
        get { loadPrefs().xfAppID ?? "" }
        set { update { $0.xfAppID = newValue } }
    }
    static var xunfeiAPIKey: String? { try? KeychainStore.load(id: xunfeiAPIKeyID) }
    static var xunfeiAPISecret: String? { try? KeychainStore.load(id: xunfeiAPISecretID) }
    static var xunfeiVoice: String {
        get { loadPrefs().xfVoice ?? "xiaoyan" }
        set { update { $0.xfVoice = newValue } }
    }

    // MARK: - 按引擎取音色(不同引擎音色名空间不同)

    static func voices(for engine: TTSEngineKind) -> [TTSVoice] {
        switch engine {
        case .siliconflow: return siliconflowVoices
        case .xunfei:      return xunfeiVoices
        default:           return voices
        }
    }
    static func voice(for engine: TTSEngineKind) -> String {
        switch engine {
        case .siliconflow: return siliconflowVoice
        case .xunfei:      return xunfeiVoice
        default:           return voice
        }
    }
    static func setVoice(_ v: String, for engine: TTSEngineKind) {
        switch engine {
        case .siliconflow: siliconflowVoice = v
        case .xunfei:      xunfeiVoice = v
        default:           voice = v
        }
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
