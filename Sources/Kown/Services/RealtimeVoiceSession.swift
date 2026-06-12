import Foundation

// MARK: - 「实时双工(Beta)」配置

/// 实时双工语音的可调配置(UserDefaults 持久化)。
/// Live 模型是 preview 名、迭代快,模型名/音色/WS 地址都做成可改的默认值:
/// 官方更名或用户走中转时,不用等发版就能自救。
enum RealtimeVoiceConfig {
    static let modelKey = "kown.realtime.model.v1"
    static let voiceKey = "kown.realtime.voice.v1"
    static let wsBaseURLKey = "kown.realtime.wsBaseURL.v1"

    /// 2026-06 当前的原生音频对话模型(Live API / BidiGenerateContent):
    /// - gemini-3.1-flash-live-preview:最新低延迟 audio-to-audio(2026-03 上新,默认)
    /// - gemini-2.5-flash-native-audio-preview-12-2025:上一代原生音频,兼容退路
    static let defaultModel = "gemini-3.1-flash-live-preview"
    static let suggestedModels = [
        "gemini-3.1-flash-live-preview",
        "gemini-2.5-flash-native-audio-preview-12-2025",
    ]

    /// 默认音色(官方文档示例音色,中英文都自然)。
    static let defaultVoice = "Kore"
    static let suggestedVoices = ["Kore", "Puck", "Charon", "Fenrir", "Aoede", "Leda", "Orus", "Zephyr"]

    static var model: String {
        get {
            let v = UserDefaults.standard.string(forKey: modelKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return v.isEmpty ? defaultModel : v
        }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }

    static var voiceName: String {
        get {
            let v = UserDefaults.standard.string(forKey: voiceKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return v.isEmpty ? defaultVoice : v
        }
        set { UserDefaults.standard.set(newValue, forKey: voiceKey) }
    }

    /// 自定义 WS base(中转用户),空 = 官方 `wss://generativelanguage.googleapis.com`。
    /// 支持填 `https://` / `wss://` 前缀或裸 host;若已含完整 BidiGenerateContent 路径则原样使用。
    static var wsBaseURL: String {
        get { UserDefaults.standard.string(forKey: wsBaseURLKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: wsBaseURLKey) }
    }
}

// MARK: - Live 协议消息(Codable,纯结构、可单测)

/// base64 音频块。上行 `audio/pcm;rate=16000`,下行 `audio/pcm;rate=24000`。
struct LiveBlob: Codable, Equatable, Sendable {
    var mimeType: String
    var data: String

    init(mimeType: String, data: String) {
        self.mimeType = mimeType
        self.data = data
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? ""
        self.data = try c.decodeIfPresent(String.self, forKey: .data) ?? ""
    }
}

struct LivePart: Codable, Equatable, Sendable {
    var text: String?
    var inlineData: LiveBlob?

    init(text: String? = nil, inlineData: LiveBlob? = nil) {
        self.text = text
        self.inlineData = inlineData
    }
}

struct LiveContent: Codable, Equatable, Sendable {
    var role: String?
    var parts: [LivePart]?

    init(role: String? = nil, parts: [LivePart]? = nil) {
        self.role = role
        self.parts = parts
    }
}

struct LivePrebuiltVoiceConfig: Codable, Equatable, Sendable {
    var voiceName: String
}

struct LiveVoiceConfig: Codable, Equatable, Sendable {
    var prebuiltVoiceConfig: LivePrebuiltVoiceConfig
}

struct LiveSpeechConfig: Codable, Equatable, Sendable {
    var voiceConfig: LiveVoiceConfig
}

struct LiveGenerationConfig: Codable, Equatable, Sendable {
    var responseModalities: [String]
    var speechConfig: LiveSpeechConfig?

    init(responseModalities: [String], speechConfig: LiveSpeechConfig? = nil) {
        self.responseModalities = responseModalities
        self.speechConfig = speechConfig
    }
}

/// 空配置对象(`{}`):出现即代表「开启」。
struct LiveAudioTranscriptionConfig: Codable, Equatable, Sendable {
    init() {}
}

/// setup 帧:WS 连上后的第一条消息,之后必须等 setupComplete 才能继续发。
struct LiveSetup: Codable, Equatable, Sendable {
    var model: String                       // 必须是 "models/<id>" 形式
    var generationConfig: LiveGenerationConfig?
    var systemInstruction: LiveContent?
    var inputAudioTranscription: LiveAudioTranscriptionConfig?
    var outputAudioTranscription: LiveAudioTranscriptionConfig?

    init(model: String,
         generationConfig: LiveGenerationConfig? = nil,
         systemInstruction: LiveContent? = nil,
         inputAudioTranscription: LiveAudioTranscriptionConfig? = nil,
         outputAudioTranscription: LiveAudioTranscriptionConfig? = nil) {
        self.model = model
        self.generationConfig = generationConfig
        self.systemInstruction = systemInstruction
        self.inputAudioTranscription = inputAudioTranscription
        self.outputAudioTranscription = outputAudioTranscription
    }
}

/// realtimeInput 帧:实时音频/文本上行。`audio` 取代已废弃的 `mediaChunks`;
/// `audioStreamEnd` 在(服务端 VAD 开启时)麦克风静音/关闭时发一次。
struct LiveRealtimeInput: Codable, Equatable, Sendable {
    var audio: LiveBlob?
    var text: String?
    var audioStreamEnd: Bool?

    init(audio: LiveBlob? = nil, text: String? = nil, audioStreamEnd: Bool? = nil) {
        self.audio = audio
        self.text = text
        self.audioStreamEnd = audioStreamEnd
    }
}

/// 客户端消息信封:每条恰好带一个字段。
struct LiveClientEnvelope: Codable, Equatable, Sendable {
    var setup: LiveSetup?
    var realtimeInput: LiveRealtimeInput?

    init(setup: LiveSetup? = nil, realtimeInput: LiveRealtimeInput? = nil) {
        self.setup = setup
        self.realtimeInput = realtimeInput
    }
}

// MARK: 服务端消息

struct LiveTranscription: Codable, Equatable, Sendable {
    var text: String?
    var finished: Bool?

    init(text: String? = nil, finished: Bool? = nil) {
        self.text = text
        self.finished = finished
    }
}

/// serverContent:**一条消息可同时含多个 part(音频块 + 字幕),必须全部处理**
/// (gemini-3.1 迁移说明明确要求,否则会丢内容)。
struct LiveServerContent: Codable, Equatable, Sendable {
    var modelTurn: LiveContent?
    var inputTranscription: LiveTranscription?
    var outputTranscription: LiveTranscription?
    var interrupted: Bool?
    var turnComplete: Bool?
    var generationComplete: Bool?

    init(modelTurn: LiveContent? = nil,
         inputTranscription: LiveTranscription? = nil,
         outputTranscription: LiveTranscription? = nil,
         interrupted: Bool? = nil,
         turnComplete: Bool? = nil,
         generationComplete: Bool? = nil) {
        self.modelTurn = modelTurn
        self.inputTranscription = inputTranscription
        self.outputTranscription = outputTranscription
        self.interrupted = interrupted
        self.turnComplete = turnComplete
        self.generationComplete = generationComplete
    }
}

struct LiveGoAway: Codable, Equatable, Sendable {
    var timeLeft: String?

    init(timeLeft: String? = nil) { self.timeLeft = timeLeft }
}

/// 空对象占位(setupComplete / usageMetadata / toolCall 等只需「出现过」)。
struct LiveIgnoredObject: Codable, Equatable, Sendable {
    init() {}
    init(from decoder: Decoder) throws {}   // 任意对象都解码成功,内容忽略
    func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: NeverKey.self)
    }
    private enum NeverKey: CodingKey {}
}

/// 错误帧载荷。**兼容两种形态**:对象 `{"code":429,"message":"...","status":"..."}`
/// 或纯字符串 `"error": "..."`(Anthropic SSE 曾因 error 为字符串被默默吞掉 → 空响应,前科必防)。
struct LiveErrorValue: Codable, Equatable, Sendable {
    var code: Int?
    var message: String?
    var status: String?

    init(code: Int? = nil, message: String? = nil, status: String? = nil) {
        self.code = code
        self.message = message
        self.status = status
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let s = try? single.decode(String.self) {
            self.message = s
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try c.decodeIfPresent(Int.self, forKey: .code)
        self.message = try c.decodeIfPresent(String.self, forKey: .message)
        self.status = try c.decodeIfPresent(String.self, forKey: .status)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(code, forKey: .code)
        try c.encodeIfPresent(message, forKey: .message)
        try c.encodeIfPresent(status, forKey: .status)
    }

    private enum CodingKeys: String, CodingKey { case code, message, status }

    var readable: String {
        var parts: [String] = []
        if let code { parts.append("code=\(code)") }
        if let status, !status.isEmpty { parts.append(status) }
        parts.append((message?.isEmpty == false) ? message! : "未知错误")
        return parts.joined(separator: " ")
    }
}

/// 服务端消息信封。所有字段 optional + decodeIfPresent 语义(synthesized),未知键自动忽略。
struct LiveServerEnvelope: Codable, Equatable, Sendable {
    var setupComplete: LiveIgnoredObject?
    var serverContent: LiveServerContent?
    var goAway: LiveGoAway?
    var usageMetadata: LiveIgnoredObject?
    var toolCall: LiveIgnoredObject?
    var error: LiveErrorValue?

    init(setupComplete: LiveIgnoredObject? = nil,
         serverContent: LiveServerContent? = nil,
         goAway: LiveGoAway? = nil,
         usageMetadata: LiveIgnoredObject? = nil,
         toolCall: LiveIgnoredObject? = nil,
         error: LiveErrorValue? = nil) {
        self.setupComplete = setupComplete
        self.serverContent = serverContent
        self.goAway = goAway
        self.usageMetadata = usageMetadata
        self.toolCall = toolCall
        self.error = error
    }
}

// MARK: - 会话事件

/// 协议层吐给 UI/管线的事件。Sendable + Equatable(便于单测断言)。
enum RealtimeVoiceEvent: Equatable, Sendable {
    case setupComplete
    /// 24kHz PCM16 mono 音频块(已 base64 解码),直接进播放队列。
    case audioChunk(Data)
    /// 用户语音的增量转写(追加语义)。
    case inputTranscript(String)
    /// 模型语音的增量转写(追加语义)。
    case outputTranscript(String)
    /// 服务端 VAD 判定用户插话 → 立即停播清队列(barge-in)。
    case interrupted
    case turnComplete
    case generationComplete
    /// 服务端预告即将断开(配额/时长),timeLeft 如 "10s"。
    case goAway(String?)
    /// 显式错误帧(官方 / 中转网关)。**必须呈现给用户**,不许吞。
    case serverError(String)
    /// WebSocket 关闭(握手失败 / 服务端断开 / 网络错误)。
    case closed(code: Int, reason: String?)
}

// MARK: - 纯函数解析层(可单测,不碰网络)

enum RealtimeLiveParser {
    static let officialBase = "wss://generativelanguage.googleapis.com"
    static let bidiPath = "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    /// 组 WS endpoint。customBase 支持 `https://`/`wss://`/裸 host;
    /// 已含 BidiGenerateContent 完整路径时原样使用,只追加 key。
    static func endpointURL(apiKey: String, customBase: String?) -> URL? {
        var base = (customBase ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = officialBase }
        if base.hasPrefix("https://") {
            base = "wss://" + base.dropFirst("https://".count)
        } else if base.hasPrefix("http://") {
            base = "ws://" + base.dropFirst("http://".count)
        } else if !base.hasPrefix("ws://") && !base.hasPrefix("wss://") {
            base = "wss://" + base
        }
        while base.hasSuffix("/") { base.removeLast() }
        let full = base.contains("BidiGenerateContent") ? base : base + bidiPath
        guard var comps = URLComponents(string: full) else { return nil }
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "key", value: apiKey))
        comps.queryItems = items
        return comps.url
    }

    /// 解析一条 WS 消息 → 事件序列。认不出来的帧返回原文(调用方记 DebugLog,不许默默吞)。
    static func parse(_ message: URLSessionWebSocketTask.Message)
        -> (events: [RealtimeVoiceEvent], unrecognizedRaw: String?) {
        switch message {
        case .string(let s): return decodeServerEvents(Data(s.utf8))
        case .data(let d):   return decodeServerEvents(d)
        @unknown default:    return ([], "(未知 WS 帧类型)")
        }
    }

    /// 纯解码:一帧 JSON → [事件]。一帧可能同时携带音频 + 字幕 + turnComplete,全部展开。
    static func decodeServerEvents(_ data: Data) -> (events: [RealtimeVoiceEvent], unrecognizedRaw: String?) {
        guard let env = try? JSONDecoder().decode(LiveServerEnvelope.self, from: data) else {
            return ([], String(data: data, encoding: .utf8) ?? "(无法解码的二进制帧 \(data.count)B)")
        }
        var events: [RealtimeVoiceEvent] = []
        if let err = env.error {
            events.append(.serverError(err.readable))
        }
        if env.setupComplete != nil {
            events.append(.setupComplete)
        }
        if let sc = env.serverContent {
            let interrupted = sc.interrupted == true
            if interrupted { events.append(.interrupted) }
            if let t = sc.inputTranscription?.text, !t.isEmpty {
                events.append(.inputTranscript(t))
            }
            if let t = sc.outputTranscription?.text, !t.isEmpty {
                events.append(.outputTranscript(t))
            }
            // 打断帧里残留的音频 part 属于被掐掉的旧回答,直接丢弃(规范要求清空播放队列)。
            if !interrupted {
                for part in sc.modelTurn?.parts ?? [] {
                    if let blob = part.inlineData,
                       blob.mimeType.lowercased().hasPrefix("audio/"),
                       let d = Data(base64Encoded: blob.data), !d.isEmpty {
                        events.append(.audioChunk(d))
                    }
                }
            }
            if sc.generationComplete == true { events.append(.generationComplete) }
            if sc.turnComplete == true { events.append(.turnComplete) }
        }
        if let ga = env.goAway {
            events.append(.goAway(ga.timeLeft))
        }
        // 一个键都没认出来(也不是 usage/toolCall 这类已知可忽略帧)→ 交还原文给调用方记日志。
        if events.isEmpty, env.usageMetadata == nil, env.toolCall == nil,
           env.setupComplete == nil, env.serverContent == nil, env.goAway == nil {
            return ([], String(data: data, encoding: .utf8))
        }
        return (events, nil)
    }
}

// MARK: - WebSocket 会话

/// Gemini Live(BidiGenerateContent)双向流会话。协议层只管:连 → setup → 收发帧 → 事件回调。
/// 音频采集/播放在 `RealtimeAudioPipeline`,编排在 `RealtimeVoiceController`(UI 层)。
///
/// 错误纪律(「SSE 错误被吞成空响应」前科):
/// - 显式 error 帧 → `.serverError` 事件 + DebugLogStore 记原文;
/// - 认不出的帧 → DebugLogStore 记原文;
/// - WS 断开 → `.closed(code,reason)` + DebugLogStore 记 closeCode/reason/底层错误。
@MainActor
final class RealtimeVoiceSession {
    private var ws: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var modelForLog = ""
    /// close() 之后丢弃迟到事件,避免「手动结束」还弹断开错误。
    private(set) var isClosed = false

    /// 事件回调(主线程)。
    var onEvent: ((RealtimeVoiceEvent) -> Void)?

    /// 连接并发送 setup。失败路径全部走事件(serverError / closed),不抛错。
    func connect(apiKey: String,
                 model: String,
                 voiceName: String,
                 systemInstruction: String?,
                 customBaseURL: String?) {
        closeTransportOnly()
        isClosed = false
        modelForLog = model

        guard let url = RealtimeLiveParser.endpointURL(apiKey: apiKey, customBase: customBaseURL) else {
            onEvent?(.serverError("WS 地址构造失败,请检查自定义中转地址"))
            return
        }
        // 用 shared session:每次进实时模式都会新建本类实例,自建 URLSession 不 invalidate 会泄漏。
        let task = URLSession.shared.webSocketTask(with: url)
        ws = task
        task.resume()

        let modelPath = model.hasPrefix("models/") ? model : "models/" + model
        let setup = LiveSetup(
            model: modelPath,
            generationConfig: LiveGenerationConfig(
                responseModalities: ["AUDIO"],
                speechConfig: LiveSpeechConfig(
                    voiceConfig: LiveVoiceConfig(
                        prebuiltVoiceConfig: LivePrebuiltVoiceConfig(voiceName: voiceName)))),
            systemInstruction: systemInstruction.flatMap { sys in
                let t = sys.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : LiveContent(parts: [LivePart(text: t)])
            },
            inputAudioTranscription: LiveAudioTranscriptionConfig(),
            outputAudioTranscription: LiveAudioTranscriptionConfig()
        )
        let envelope = LiveClientEnvelope(setup: setup)
        if DebugLogStore.isEnabled,
           let data = try? JSONEncoder().encode(envelope),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            DebugLogStore.record(model: model, method: "WS", url: url.absoluteString,
                                 body: dict, status: nil, responseRaw: "(已发送 setup,等待 setupComplete)",
                                 error: nil, startedAt: Date())
        }
        sendEnvelope(envelope)
        startReceiveLoop(task)
    }

    /// 上行一片 16kHz PCM16 mono(每片 ~100–200ms,由管线分好)。
    func sendAudioChunk(_ pcm16: Data) {
        guard !pcm16.isEmpty else { return }
        sendEnvelope(LiveClientEnvelope(realtimeInput: LiveRealtimeInput(
            audio: LiveBlob(mimeType: "audio/pcm;rate=16000", data: pcm16.base64EncodedString()))))
    }

    /// 麦克风静音/关闭时发一次(服务端 VAD 开启时的规范信号);再次发音频即自动重开流。
    func sendAudioStreamEnd() {
        sendEnvelope(LiveClientEnvelope(realtimeInput: LiveRealtimeInput(audioStreamEnd: true)))
    }

    /// 实时文本上行(留给打字补充说明等场景)。
    func sendText(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        sendEnvelope(LiveClientEnvelope(realtimeInput: LiveRealtimeInput(text: t)))
    }

    func close() {
        isClosed = true
        closeTransportOnly()
    }

    private func closeTransportOnly() {
        receiveTask?.cancel()
        receiveTask = nil
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
    }

    private func sendEnvelope(_ env: LiveClientEnvelope) {
        guard let ws else { return }
        guard let data = try? JSONEncoder().encode(env),
              let json = String(data: data, encoding: .utf8) else { return }
        ws.send(.string(json)) { _ in
            // 发送失败必然伴随 receive 抛错 → 统一由接收环路报 .closed,这里不重复造事件。
        }
    }

    private func startReceiveLoop(_ task: URLSessionWebSocketTask) {
        let model = modelForLog
        let urlStr = task.originalRequest?.url?.absoluteString ?? ""
        receiveTask = Task.detached { [weak self, task] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    // 解码在后台线程做(音频帧 base64 几十 KB,不进主线程 — CPU 卡死前科)。
                    let (events, unrecognized) = RealtimeLiveParser.parse(message)
                    if let unrecognized {
                        DebugLogStore.record(model: model, method: "WS", url: urlStr, body: [:],
                                             status: nil, responseRaw: unrecognized,
                                             error: "未识别的 Live 帧(原文见下,已忽略)", startedAt: Date())
                    }
                    guard !events.isEmpty else { continue }
                    for e in events {
                        if case .serverError(let msg) = e {
                            DebugLogStore.record(model: model, method: "WS", url: urlStr, body: [:],
                                                 status: nil, responseRaw: msg,
                                                 error: "Live 错误帧:\(msg)", startedAt: Date())
                        }
                    }
                    await MainActor.run { [weak self] in
                        guard let self, !self.isClosed else { return }
                        for e in events { self.onEvent?(e) }
                    }
                } catch {
                    if Task.isCancelled { break }
                    let code = task.closeCode.rawValue
                    let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) }
                    DebugLogStore.record(model: model, method: "WS", url: urlStr, body: [:],
                                         status: nil, responseRaw: reason ?? "",
                                         error: "WebSocket 断开 closeCode=\(code) \(error.localizedDescription)",
                                         startedAt: Date())
                    let fallbackReason = reason ?? (error.localizedDescription.isEmpty ? nil : error.localizedDescription)
                    await MainActor.run { [weak self] in
                        guard let self, !self.isClosed else { return }
                        self.onEvent?(.closed(code: code, reason: fallbackReason))
                    }
                    break
                }
            }
        }
    }
}
