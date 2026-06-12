import Foundation
import AVFoundation

/// 实时双工的音频管线:**一个 AVAudioEngine 同时负责采集(上行)与播放(下行)**。
/// 单引擎是刻意的 —— 回声消除(VoiceProcessingIO)只消除「同一 IO 单元」输出的声音,
/// 模型语音走同一个 engine 的 outputNode,扬声器外放时麦克风才不会把模型自己的话录回去
/// (否则服务端 VAD 会把回放当用户插话,无限自我打断)。
///
/// - 上行:inputNode tap → AVAudioConverter 重采样 16kHz PCM16 mono → ~150ms 分片回调。
/// - 下行:24kHz PCM16 → Float32 → AVAudioPlayerNode 队列流式播放;`stopPlayback()` 立即清队列(barge-in)。
///
/// 线程模型(同 SpeechRecognizer / VoiceActivityDetector 前例):**不标 `@MainActor`** ——
/// tap / 播放完成回调都在音频线程,标 MainActor 会让 Swift 6 在后台线程做执行器断言而崩溃。
/// 共享状态用 NSLock 保护;对外回调统一派发回主线程。
final class RealtimeAudioPipeline: NSObject, @unchecked Sendable {
    /// Live API 上行要求:16kHz PCM16 mono LE(`audio/pcm;rate=16000`)。
    static let inputSampleRate: Double = 16_000
    /// Live API 下行固定:24kHz PCM16 mono LE。
    static let outputSampleRate: Double = 24_000
    /// 上行分片目标:~150ms @ 16kHz×2B = 4800B(官方建议 100–200ms 一片)。
    private let chunkBytes = 4800

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var playerAttached = false
    private var converter: AVAudioConverter?
    /// 上行目标格式(interleaved Int16,直接 memcpy 成字节流)。
    private let sendFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                           sampleRate: RealtimeAudioPipeline.inputSampleRate,
                                           channels: 1, interleaved: true)!
    /// 下行播放格式(Float32 标准格式,mainMixer 自动转硬件采样率)。
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: RealtimeAudioPipeline.outputSampleRate,
                                           channels: 1)!

    private let lock = NSLock()
    private var pendingUpstream = Data()
    private var muted = false
    private var running = false
    /// 播放队列里未播完的 buffer 数;归零 = 模型这轮语音播完(驱动「对方说话」指示灯)。
    private var scheduledBuffers = 0
    private var configChangeObserver: NSObjectProtocol?

    /// 一片 16kHz PCM16 mono 上行数据就绪(主线程)。
    var onChunk: ((Data) -> Void)?
    /// 播放队列清空 = 模型说完 / 被打断后清完(主线程)。
    var onPlaybackDrained: (() -> Void)?
    /// 引擎配置变化(插拔耳机 / 切输出设备),引擎已自动停;调用方应重启管线(主线程)。
    var onConfigurationChange: (() -> Void)?

    /// 回声消除是否真的启用了。失败时降级继续跑,UI 据此提示「建议戴耳机」。
    private(set) var echoCancellationActive = false

    // MARK: - 生命周期

    /// 启动采集 + 播放。失败抛错(调用方呈现给用户),内部已自行回滚。主线程调用。
    func start() throws {
        lock.lock()
        let already = running
        lock.unlock()
        guard !already else { return }

        #if os(iOS)
        // 接管音频会话:双工必须 playAndRecord + voiceChat(系统级 AEC / 人声优化)。
        // 不动现有语音模式 / TTS 的逻辑 —— 它们每次启动都自设 category,退出实时模式
        // 时 stop() 里 setActive(false) 即等效恢复原状。
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        try session.setActive(true)
        #endif

        let input = engine.inputNode
        // 回声消除(mac+iOS)。必须在引擎启动前设置;失败不致命 → 降级 + UI 提示戴耳机。
        if !echoCancellationActive {
            do {
                try input.setVoiceProcessingEnabled(true)
                echoCancellationActive = true
            } catch {
                echoCancellationActive = false
            }
        }

        // VP 开启后输入格式可能变化(mac 上常变 mono),tap 格式必须在那之后取。
        let tapFormat = input.outputFormat(forBus: 0)
        guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
            throw NSError(domain: "Kown.RealtimeAudioPipeline", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "音频输入设备不可用,请检查麦克风"])
        }
        guard let conv = AVAudioConverter(from: tapFormat, to: sendFormat) else {
            throw NSError(domain: "Kown.RealtimeAudioPipeline", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建 16kHz 重采样器(输入格式 \(Int(tapFormat.sampleRate))Hz)"])
        }
        converter = conv

        if !playerAttached {
            engine.attach(player)
            playerAttached = true
        }
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)

        // 防御:残留 tap 上重复 installTap 会抛 NSException 直接崩(SpeechRecognizer 同款前例)。
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: tapFormat) { [weak self] buffer, _ in
            self?.captureTap(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        player.play()

        lock.lock()
        running = true
        pendingUpstream = Data()
        scheduledBuffers = 0
        lock.unlock()

        installConfigChangeObserverIfNeeded()
    }

    /// 彻底停止并释放:摘 tap、停引擎、(iOS)交还音频会话。可重入,主线程调用。
    func stop() {
        lock.lock()
        running = false
        pendingUpstream = Data()
        lock.unlock()

        if let token = configChangeObserver {
            NotificationCenter.default.removeObserver(token)
            configChangeObserver = nil
        }
        player.stop()
        // 无条件摘 tap:即使 start 半路失败,tap 也可能挂着。
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        #if os(iOS)
        // 交还会话;现有 TTS / 听写各自启动时会重设自己的 category,等效「恢复原状」。
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    // MARK: - 上行(麦克风)

    /// 静音:不再产出上行分片(引擎保持运行,解除立即恢复)。静音瞬间清掉攒了一半的分片。
    func setMuted(_ on: Bool) {
        lock.lock()
        muted = on
        if on { pendingUpstream = Data() }
        lock.unlock()
    }

    /// tap 回调(音频线程):重采样 → 攒分片 → 满 ~150ms 派发主线程。不碰 SwiftUI / MainActor。
    private func captureTap(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let active = running && !muted
        lock.unlock()
        guard active, let converter else { return }

        let ratio = Self.inputSampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard capacity > 0,
              let out = AVAudioPCMBuffer(pcmFormat: sendFormat, frameCapacity: capacity) else { return }

        // 一次喂一块的标准转换:converter 实例跨回调复用,保证重采样滤波器状态连续。
        var fed = false
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let ch = out.int16ChannelData?[0] else { return }
        // Apple 硬件即小端,Int16 内存布局 = 协议要求的 PCM16 LE。
        let bytes = Data(bytes: ch, count: Int(out.frameLength) * 2)

        var toSend: Data?
        lock.lock()
        if running && !muted {
            pendingUpstream.append(bytes)
            if pendingUpstream.count >= chunkBytes {
                toSend = pendingUpstream
                pendingUpstream = Data()
            }
        }
        lock.unlock()
        if let toSend {
            DispatchQueue.main.async { [weak self] in self?.onChunk?(toSend) }
        }
    }

    // MARK: - 下行(模型语音)

    /// 入队一块 24kHz PCM16 mono(已 base64 解码),立即流式排播。主线程调用。
    func enqueuePlayback(_ pcm: Data) {
        lock.lock()
        let active = running
        lock.unlock()
        guard active else { return }

        let frames = pcm.count / 2
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames)),
              let dst = buf.floatChannelData?[0] else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            // 不强求 2 字节对齐(Data 切片可能不对齐),逐样本读字节组装。
            for i in 0..<frames {
                let lo = UInt16(raw[i * 2])
                let hi = UInt16(raw[i * 2 + 1])
                let sample = Int16(bitPattern: hi << 8 | lo)
                dst[i] = Float(sample) / 32768.0
            }
        }

        lock.lock()
        scheduledBuffers += 1
        lock.unlock()
        // .dataPlayedBack:真正「听完」(含输出延迟)才回调;player.stop() 清队列时也会逐个触发。
        player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            var drained = false
            self.lock.lock()
            self.scheduledBuffers -= 1
            drained = self.scheduledBuffers <= 0
            self.lock.unlock()
            if drained {
                DispatchQueue.main.async { [weak self] in self?.onPlaybackDrained?() }
            }
        }
        if !player.isPlaying { player.play() }
    }

    /// barge-in:立即停播并清空全部排队 buffer(`interrupted` 帧的规范动作),再重新武装等下一轮。
    func stopPlayback() {
        lock.lock()
        let active = running
        lock.unlock()
        guard active else { return }
        player.stop()   // 清队列;每个被冲掉的 buffer 的 completion 仍会触发 → 计数自然归零
        player.play()
    }

    // MARK: - 配置变化(插拔耳机 / 切设备)

    private func installConfigChangeObserverIfNeeded() {
        guard configChangeObserver == nil else { return }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let active = self.running
            self.lock.unlock()
            guard active else { return }
            DispatchQueue.main.async { [weak self] in self?.onConfigurationChange?() }
        }
    }

    // MARK: - 麦克风权限(回调派发主线程;模式同 SpeechRecognizer)

    static func requestMicPermission(_ completion: @escaping @Sendable (Bool) -> Void) {
        let finish: @Sendable (Bool) -> Void = { ok in
            DispatchQueue.main.async { completion(ok) }
        }
        #if os(iOS)
        AVAudioApplication.requestRecordPermission { finish($0) }
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    finish(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { finish($0) }
        default:             finish(false)
        }
        #endif
    }
}
