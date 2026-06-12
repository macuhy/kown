import XCTest
@testable import Kown

/// 「实时双工(Beta)」Gemini Live(BidiGenerateContent)协议消息编解码的纯结构单测。
/// 不依赖网络:只验证 Codable 模型、`RealtimeLiveParser` 的解析与 endpoint 构造。
/// 重点防「错误/异常帧被默默吞成空响应」前科 —— error 帧(对象 + 字符串两种形态)
/// 与认不出来的帧都必须有可观测产物。
final class RealtimeVoiceProtocolTests: XCTestCase {

    // MARK: 上行编码

    /// setup 帧:model 形如 models/<id>、responseModalities=AUDIO、音色、输入+输出转写都在。
    func testSetupEnvelopeEncodes() throws {
        let setup = LiveSetup(
            model: "models/gemini-3.1-flash-live-preview",
            generationConfig: LiveGenerationConfig(
                responseModalities: ["AUDIO"],
                speechConfig: LiveSpeechConfig(
                    voiceConfig: LiveVoiceConfig(
                        prebuiltVoiceConfig: LivePrebuiltVoiceConfig(voiceName: "Kore")))),
            systemInstruction: LiveContent(parts: [LivePart(text: "你是助手")]),
            inputAudioTranscription: LiveAudioTranscriptionConfig(),
            outputAudioTranscription: LiveAudioTranscriptionConfig())
        let env = LiveClientEnvelope(setup: setup)
        let data = try JSONEncoder().encode(env)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let s = try XCTUnwrap(json["setup"] as? [String: Any])
        XCTAssertEqual(s["model"] as? String, "models/gemini-3.1-flash-live-preview")
        let gc = try XCTUnwrap(s["generationConfig"] as? [String: Any])
        XCTAssertEqual(gc["responseModalities"] as? [String], ["AUDIO"])
        XCTAssertNotNil(gc["speechConfig"])
        // 空对象配置 `{}` 必须出现(代表「开启」)。
        XCTAssertNotNil(s["inputAudioTranscription"])
        XCTAssertNotNil(s["outputAudioTranscription"])
        XCTAssertNotNil(s["systemInstruction"])
    }

    /// realtimeInput 上行音频:mimeType=audio/pcm;rate=16000,data 为 base64。
    func testRealtimeInputAudioEncodes() throws {
        let raw = Data([0x01, 0x02, 0x03, 0x04])
        let env = LiveClientEnvelope(realtimeInput: LiveRealtimeInput(
            audio: LiveBlob(mimeType: "audio/pcm;rate=16000", data: raw.base64EncodedString())))
        let data = try JSONEncoder().encode(env)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ri = try XCTUnwrap(json["realtimeInput"] as? [String: Any])
        let audio = try XCTUnwrap(ri["audio"] as? [String: Any])
        XCTAssertEqual(audio["mimeType"] as? String, "audio/pcm;rate=16000")
        XCTAssertEqual(audio["data"] as? String, raw.base64EncodedString())
    }

    func testRealtimeInputAudioStreamEndEncodes() throws {
        let env = LiveClientEnvelope(realtimeInput: LiveRealtimeInput(audioStreamEnd: true))
        let data = try JSONEncoder().encode(env)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ri = try XCTUnwrap(json["realtimeInput"] as? [String: Any])
        XCTAssertEqual(ri["audioStreamEnd"] as? Bool, true)
    }

    // MARK: 下行解析 — setupComplete

    func testParseSetupComplete() {
        let (events, raw) = RealtimeLiveParser.decodeServerEvents(Data(#"{"setupComplete":{}}"#.utf8))
        XCTAssertNil(raw)
        XCTAssertEqual(events, [.setupComplete])
    }

    // MARK: 下行解析 — serverContent 多 part(音频 + 字幕一帧同发,必须全展开)

    func testParseServerContentAudioAndTranscripts() {
        let pcm = Data([0xAA, 0xBB, 0xCC, 0xDD])
        let b64 = pcm.base64EncodedString()
        let json = """
        {"serverContent":{
          "inputTranscription":{"text":"你好"},
          "outputTranscription":{"text":"你也好"},
          "modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"\(b64)"}}]}
        }}
        """
        let (events, raw) = RealtimeLiveParser.decodeServerEvents(Data(json.utf8))
        XCTAssertNil(raw)
        XCTAssertTrue(events.contains(.inputTranscript("你好")))
        XCTAssertTrue(events.contains(.outputTranscript("你也好")))
        XCTAssertTrue(events.contains(.audioChunk(pcm)), "音频 part 应被 base64 解码成 audioChunk")
    }

    func testParseTurnComplete() {
        let (events, _) = RealtimeLiveParser.decodeServerEvents(
            Data(#"{"serverContent":{"turnComplete":true}}"#.utf8))
        XCTAssertTrue(events.contains(.turnComplete))
    }

    // MARK: 下行解析 — interrupted(barge-in):产出 .interrupted 且丢弃残留音频

    func testParseInterruptedDropsResidualAudio() {
        let pcm = Data([0x10, 0x20])
        let b64 = pcm.base64EncodedString()
        let json = """
        {"serverContent":{"interrupted":true,
          "modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"\(b64)"}}]}}}
        """
        let (events, _) = RealtimeLiveParser.decodeServerEvents(Data(json.utf8))
        XCTAssertTrue(events.contains(.interrupted), "应产出 interrupted 事件")
        XCTAssertFalse(events.contains(.audioChunk(pcm)),
                       "interrupted 帧里的残留音频属于被掐掉的旧回答,必须丢弃")
    }

    // MARK: 下行解析 — error 帧两种形态都不能被吞

    func testParseErrorObjectForm() {
        let json = #"{"error":{"code":429,"message":"配额超限","status":"RESOURCE_EXHAUSTED"}}"#
        let (events, raw) = RealtimeLiveParser.decodeServerEvents(Data(json.utf8))
        XCTAssertNil(raw)
        guard case .serverError(let msg)? = events.first else {
            return XCTFail("error 对象帧应产出 serverError 事件,实际:\(events)")
        }
        XCTAssertTrue(msg.contains("429"))
        XCTAssertTrue(msg.contains("配额超限"))
    }

    /// error 为纯字符串(Anthropic SSE 前科:字符串错误被默默吞)。这里必须仍产出 serverError。
    func testParseErrorStringForm() {
        let json = #"{"error":"无效的 API key"}"#
        let (events, _) = RealtimeLiveParser.decodeServerEvents(Data(json.utf8))
        guard case .serverError(let msg)? = events.first else {
            return XCTFail("error 字符串帧应产出 serverError 事件,实际:\(events)")
        }
        XCTAssertTrue(msg.contains("无效的 API key"))
    }

    // MARK: 下行解析 — goAway 预告

    func testParseGoAway() {
        let (events, _) = RealtimeLiveParser.decodeServerEvents(
            Data(#"{"goAway":{"timeLeft":"10s"}}"#.utf8))
        XCTAssertEqual(events, [.goAway("10s")])
    }

    // MARK: 下行解析 — 已知可忽略帧 / 认不出来的帧

    /// usageMetadata 是已知可忽略帧:不产事件、也不当成「未识别」回吐原文。
    func testParseKnownIgnorableFrameProducesNothing() {
        let (events, raw) = RealtimeLiveParser.decodeServerEvents(
            Data(#"{"usageMetadata":{"totalTokenCount":42}}"#.utf8))
        XCTAssertTrue(events.isEmpty)
        XCTAssertNil(raw, "usageMetadata 属已知可忽略帧,不应被当作未识别帧")
    }

    /// 完全不认识的键:无事件,但原文必须回吐给调用方记日志(绝不静默吞)。
    func testParseUnrecognizedFrameReturnsRaw() {
        let body = #"{"somethingBrandNew":{"x":1}}"#
        let (events, raw) = RealtimeLiveParser.decodeServerEvents(Data(body.utf8))
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(raw, body, "未识别帧的原文应回吐供 DebugLog 记录")
    }

    /// 非法 JSON:解码失败也要回吐原文,不能默默吞。
    func testParseMalformedJSONReturnsRaw() {
        let body = "这不是JSON{"
        let (events, raw) = RealtimeLiveParser.decodeServerEvents(Data(body.utf8))
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(raw, body)
    }

    // MARK: endpoint URL 构造

    func testEndpointDefaultBaseAppendsBidiPathAndKey() throws {
        let url = try XCTUnwrap(RealtimeLiveParser.endpointURL(apiKey: "KEY123", customBase: nil))
        let s = url.absoluteString
        XCTAssertTrue(s.hasPrefix("wss://generativelanguage.googleapis.com"))
        XCTAssertTrue(s.contains("BidiGenerateContent"))
        XCTAssertTrue(s.contains("key=KEY123"))
    }

    func testEndpointHTTPSCustomBaseUpgradedToWSS() throws {
        let url = try XCTUnwrap(RealtimeLiveParser.endpointURL(
            apiKey: "K", customBase: "https://relay.example.com"))
        let s = url.absoluteString
        XCTAssertTrue(s.hasPrefix("wss://relay.example.com"), "https:// 应升级为 wss://,实际:\(s)")
        XCTAssertTrue(s.contains("BidiGenerateContent"))
        XCTAssertTrue(s.contains("key=K"))
    }

    func testEndpointBareHostGetsWSSPrefix() throws {
        let url = try XCTUnwrap(RealtimeLiveParser.endpointURL(
            apiKey: "K", customBase: "relay.example.com/"))
        XCTAssertTrue(url.absoluteString.hasPrefix("wss://relay.example.com"))
    }

    /// 已含完整 BidiGenerateContent 路径的中转地址:原样使用,只追加 key,不重复拼路径。
    func testEndpointFullPathPreserved() throws {
        let full = "wss://relay.example.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        let url = try XCTUnwrap(RealtimeLiveParser.endpointURL(apiKey: "K", customBase: full))
        let s = url.absoluteString
        XCTAssertEqual(s.components(separatedBy: "BidiGenerateContent").count - 1, 1,
                       "BidiGenerateContent 不应被拼两次")
        XCTAssertTrue(s.contains("key=K"))
    }

    // MARK: 容错:Codable 新字段 decodeIfPresent(缺字段不崩)

    func testServerEnvelopeToleratesMissingFields() throws {
        // 空对象:所有字段 optional,应解码成功且不产事件。
        let (events, raw) = RealtimeLiveParser.decodeServerEvents(Data("{}".utf8))
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(raw, "{}")
    }

    func testBlobToleratesMissingData() throws {
        // inlineData 只给 mimeType、缺 data:不应抛错(decodeIfPresent 容错为空串)。
        let json = #"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm"}}]}}}"#
        let (events, _) = RealtimeLiveParser.decodeServerEvents(Data(json.utf8))
        // data 为空 → 不产生 audioChunk,但解析过程不崩。
        XCTAssertFalse(events.contains { if case .audioChunk = $0 { return true } else { return false } })
    }
}
