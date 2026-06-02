import Foundation
import AVFoundation

/// 回答朗读(TTS)协调器。单例,跨卡片共享:同一时间只读一段,点别处自动切换。
/// 引擎可选(设置 ▸ 朗读):硅基流动 CosyVoice / Edge / Azure / 系统语音。
/// 网络引擎**分段流式**:按句子切片,合成第一段即开播,后台同时往前合成后续段并排队连续播放
/// —— 长回答的首音延迟从「等整段」降到「等一句」。失败回退系统语音。
@MainActor
final class SpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = SpeechService()

    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var synthTask: Task<Void, Never>?

    // 分段流式播放状态
    private var pendingSegments: [Data] = []   // 已合成、待播放的 mp3 段
    private var isPlayingSegment = false
    private var producerDone = false
    /// 每次 speak/stop 自增,使旧 session 的合成/播放回调失效(避免切换时串音)。
    private var playToken = 0
    /// 预取上限:最多领先播放 3 段,避免长文一次性全合成(省成本 + 不打满限流)。
    private let prefetchAhead = 3

    // karaoke 进度状态(神经引擎按音频时长插值)
    private var segmentCharOffsets: [Int] = []   // 各段在 spokenText 内的起始 Character 偏移
    private var segmentCharLengths: [Int] = []
    private var playingSegmentIndex = -1         // 当前播放到第几段(出队计数)
    private var progressTimer: Timer?

    /// 当前正在朗读的文本(供卡片判断按钮显示「朗读」还是「停止」)。
    @Published private(set) var speakingText: String?
    /// karaoke 高亮:当前朗读的全文(= speakingText 的 trim 版,用于按游标切分)。
    @Published private(set) var spokenText: String?
    /// karaoke 高亮:已读到的字符数(`spokenText` 内 Character 计数游标)。
    @Published private(set) var spokenCharProgress: Int = 0
    /// 网络引擎首段还在合成中 — UI 可显示 loading。
    @Published private(set) var preparing: Bool = false
    /// 上次朗读的诊断信息:网络引擎失败回退/中断时记下原因(设置页展示),成功则清空。
    @Published private(set) var lastNote: String?

    private override init() {
        super.init()
        synth.delegate = self
    }

    /// 朗读 / 停止切换:正在读这段就停;否则(停掉别处后)读这段。
    func toggle(_ text: String) {
        if speakingText == text { stop(); return }
        speak(text)
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 结束上一段会话
        synthTask?.cancel()
        synthTask = nil
        stopPlaybackOnly()
        pendingSegments.removeAll()
        isPlayingSegment = false
        producerDone = false
        playToken += 1
        let token = playToken

        let engine = TTSConfig.engine
        guard engine.isNetwork else {
            systemSpeak(trimmed, original: text)
            return
        }

        speakingText = text
        spokenText = trimmed
        spokenCharProgress = 0
        preparing = true
        lastNote = nil
        let voice = TTSConfig.voice(for: engine)
        let rate = TTSConfig.ratePercent
        // 讯飞按「次」计费(每日 500 次免费),用接近字节上限的大段,尽量一次装下整篇;
        // 其他引擎按字符计费,用小段抢首音。
        let segments: [String]
        if engine == .xunfei {
            segments = Self.segments(from: trimmed, target: 1800, hardMax: 1800)
        } else {
            segments = Self.segments(from: trimmed, target: 80, hardMax: 200)
        }
        computeSegmentOffsets(segments, in: trimmed)

        synthTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var enqueuedAny = false
            do {
                for seg in segments {
                    // 预取节流:领先播放不超过 prefetchAhead 段
                    while self.pendingSegments.count >= self.prefetchAhead,
                          !Task.isCancelled, self.playToken == token {
                        try? await Task.sleep(nanoseconds: 120_000_000)
                    }
                    if Task.isCancelled || self.playToken != token { return }
                    let data = try await Self.synthesize(engine: engine, text: seg, voice: voice, rate: rate)
                    if Task.isCancelled || self.playToken != token { return }
                    self.enqueue(data, token: token)
                    enqueuedAny = true
                }
                self.producerDone = true
                self.lastNote = nil
                // 生产结束时若已播完,收尾
                if !self.isPlayingSegment && self.pendingSegments.isEmpty {
                    self.finishSession(token: token)
                }
            } catch {
                if Task.isCancelled || self.playToken != token { return }
                self.preparing = false
                if !enqueuedAny {
                    // 第一段就失败 → 整段系统语音兜底
                    self.lastNote = "「\(engine.displayName)」朗读失败,已回退系统语音(系统语音不支持切换音色):\(error.localizedDescription)"
                    self.systemSpeak(trimmed, original: text)
                } else {
                    // 已经播了一部分 → 让已入队的播完,记一条提示
                    self.producerDone = true
                    self.lastNote = "「\(engine.displayName)」后段合成失败,已朗读到中断处:\(error.localizedDescription)"
                }
            }
        }
    }

    func stop() {
        synthTask?.cancel()
        synthTask = nil
        stopPlaybackOnly()
        pendingSegments.removeAll()
        isPlayingSegment = false
        producerDone = true
        playToken += 1
        speakingText = nil
        preparing = false
        resetKaraoke()
    }

    /// 顺序定位每段在全文中的起始 Character 偏移 + 段长,供 karaoke 插值。
    private func computeSegmentOffsets(_ segments: [String], in full: String) {
        var offsets: [Int] = []
        var lengths: [Int] = []
        var cursor = full.startIndex
        for seg in segments {
            if let r = full.range(of: seg, range: cursor..<full.endIndex) {
                offsets.append(full.distance(from: full.startIndex, to: r.lowerBound))
                lengths.append(seg.count)
                cursor = r.upperBound
            } else {
                let start = (offsets.last ?? 0) + (lengths.last ?? 0)
                offsets.append(start)
                lengths.append(seg.count)
            }
        }
        segmentCharOffsets = offsets
        segmentCharLengths = lengths
        playingSegmentIndex = -1
    }

    private func resetKaraoke() {
        progressTimer?.invalidate()
        progressTimer = nil
        segmentCharOffsets = []
        segmentCharLengths = []
        playingSegmentIndex = -1
        spokenText = nil
        spokenCharProgress = 0
    }

    /// 段内按音频时长插值推进游标(神经引擎)。
    private func startProgressTimer(token: Int) {
        progressTimer?.invalidate()
        let i = playingSegmentIndex
        guard i >= 0, i < segmentCharOffsets.count else { return }
        let start = segmentCharOffsets[i]
        let len = segmentCharLengths[i]
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.playToken == token, self.isPlayingSegment, let p = self.player else { return }
                let dur = p.duration
                let frac = dur > 0 ? min(1, max(0, p.currentTime / dur)) : 0
                self.spokenCharProgress = start + Int(frac * Double(len))
            }
        }
    }

    // MARK: - 分段播放

    private func enqueue(_ data: Data, token: Int) {
        guard playToken == token else { return }
        preparing = false
        pendingSegments.append(data)
        if !isPlayingSegment { playNextSegment(token: token) }
    }

    private func playNextSegment(token: Int) {
        guard playToken == token else { return }
        guard !pendingSegments.isEmpty else {
            isPlayingSegment = false
            if producerDone { finishSession(token: token) }
            return
        }
        let data = pendingSegments.removeFirst()
        playingSegmentIndex += 1
        if playingSegmentIndex < segmentCharOffsets.count {
            spokenCharProgress = segmentCharOffsets[playingSegmentIndex]
        }
        do {
            activatePlaybackSession()
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            player = p
            isPlayingSegment = true
            startProgressTimer(token: token)
            p.play()
        } catch {
            // 这一段坏了就跳过,继续下一段
            playNextSegment(token: token)
        }
    }

    private func finishSession(token: Int) {
        guard playToken == token else { return }
        isPlayingSegment = false
        player = nil
        speakingText = nil
        preparing = false
        resetKaraoke()
    }

    // MARK: - 合成

    private static func synthesize(engine: TTSEngineKind, text: String, voice: String, rate: Int) async throws -> Data {
        switch engine {
        case .siliconflow:
            guard let key = TTSConfig.siliconflowKey, !key.isEmpty else {
                throw TTSError.notConfigured("未配置硅基流动 Key(设置 ▸ 朗读)")
            }
            return try await SiliconFlowTTSEngine(
                baseURL: TTSConfig.siliconflowBaseURL, key: key, model: TTSConfig.siliconflowModel
            ).synthesize(text: text, voiceName: voice, ratePercent: rate)
        case .xunfei:
            guard let apiKey = TTSConfig.xunfeiAPIKey, !apiKey.isEmpty,
                  let apiSecret = TTSConfig.xunfeiAPISecret, !apiSecret.isEmpty,
                  !TTSConfig.xunfeiAppID.isEmpty else {
                throw TTSError.notConfigured("未配置讯飞 APPID/APIKey/APISecret(设置 ▸ 朗读)")
            }
            return try await XunfeiTTSEngine(
                appID: TTSConfig.xunfeiAppID, apiKey: apiKey, apiSecret: apiSecret
            ).synthesize(text: text, voice: voice, ratePercent: rate)
        case .system:
            throw TTSError.notConfigured("系统语音不走该路径")
        }
    }

    private func systemSpeak(_ trimmed: String, original: String) {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        activatePlaybackSession()
        let u = AVSpeechUtterance(string: trimmed)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
            ?? AVSpeechSynthesisVoice(language: Locale.current.identifier)
        synth.speak(u)
        speakingText = original
        spokenText = trimmed
        spokenCharProgress = 0
    }

    /// 停掉当前播放(合成器 + mp3 player),但不动 speakingText/synthTask/队列。
    private func stopPlaybackOnly() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        player?.stop()
        player = nil
    }

    private func activatePlaybackSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    // MARK: - 句子切片

    /// 按句末标点把文本切成段,贪心合并到 ~target 字,单段不超过 hardMax;首段尽量短以更快出声。
    static func segments(from text: String, target: Int = 80, hardMax: Int = 200) -> [String] {
        let enders: Set<Character> = ["。", "!", "?", "；", ";", "…", "！", "？", "\n"]
        // 先按句末切成「句子」
        var sentences: [String] = []
        var cur = ""
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            cur.append(ch)
            let isEnder = enders.contains(ch)
                || (ch == "." && (i + 1 >= chars.count || chars[i + 1] == " " || chars[i + 1] == "\n"))
            if isEnder {
                let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { sentences.append(cur) }
                cur = ""
            }
        }
        if !cur.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sentences.append(cur) }
        if sentences.isEmpty { return text.isEmpty ? [] : [text] }

        // 贪心合并到 target;过长的单句按 hardMax 硬切
        var out: [String] = []
        var buf = ""
        func flush() {
            let t = buf.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(buf) }
            buf = ""
        }
        for s in sentences {
            if s.count > hardMax {
                flush()
                var rest = Array(s)
                while !rest.isEmpty {
                    let take = Array(rest.prefix(hardMax))
                    out.append(String(take))
                    rest.removeFirst(take.count)
                }
                continue
            }
            if buf.count + s.count > hardMax { flush() }
            buf += s
            if buf.count >= target { flush() }
        }
        flush()
        return out.isEmpty ? [text] : out
    }

    // MARK: - delegates

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingText = nil; self.resetKaraoke() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingText = nil; self.resetKaraoke() }
    }

    /// 系统语音逐词回调:把已读游标推进到当前词末尾(精确逐字)。
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard let text = self.spokenText, let r = Range(characterRange, in: text) else { return }
            self.spokenCharProgress = text.distance(from: text.startIndex, to: r.upperBound)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.isPlayingSegment else { return }
            self.isPlayingSegment = false
            self.player = nil
            // 段播完:游标对齐到该段末尾,再播下一段。
            let i = self.playingSegmentIndex
            if i >= 0, i < self.segmentCharOffsets.count {
                self.spokenCharProgress = self.segmentCharOffsets[i] + self.segmentCharLengths[i]
            }
            self.progressTimer?.invalidate()
            self.playNextSegment(token: self.playToken)
        }
    }
}
