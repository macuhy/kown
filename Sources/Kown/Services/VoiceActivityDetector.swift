import Foundation
import AVFoundation

/// 轻量语音活动检测(VAD)。用一个独立的 `AVAudioEngine` tap 量麦克风 RMS 能量,
/// 只回报「检测到有人开口」这一个事件 —— 给「连续对话」模式做 barge-in(打断朗读)用。
///
/// 为什么不复用 `SpeechRecognizer`:
/// - 朗读(TTS)期间要边播边监听,而 STT 会启停同一个 `AVAudioEngine`/音频会话,
///   两个全功能识别会话叠在一起容易抢设备、串音、空耗。VAD 只要「有没有声音」,
///   自己拉一个最小 tap 量能量即可,远比跑一路 SFSpeechRecognizer 省。
/// - `SpeechRecognizer.swift` 是禁改文件,barge-in 逻辑必须独立成件。
///
/// **不标 `@MainActor`**:音频 tap 回调在音频线程触发,和 `SpeechRecognizer` 同理 ——
/// 标成 MainActor 隔离会让 Swift 6 在后台线程做执行器断言而崩溃。
/// 对外的 `onSpeech` 回调统一派发回主线程。
final class VoiceActivityDetector: NSObject, @unchecked Sendable {

    /// 判定为「开口」需要连续多少帧能量高于阈值(约 100ms 一帧的话 ~ frames*hop)。
    /// 设几帧是为了滤掉爆音/键盘声等瞬态,避免误打断。
    private let triggerFrames: Int
    /// 相对基线的能量倍数阈值:当前帧 RMS 超过「基线 * factor」且超过绝对地板才算有人声。
    private let thresholdFactor: Float
    /// 绝对能量地板,过滤极安静环境下基线噪声被放大成假阳性。
    private let absoluteFloor: Float

    private let engine = AVAudioEngine()
    private var running = false
    private var baseline: Float = 0.0015      // 自适应噪声基线(EMA)
    private var hotFrames = 0                 // 连续超阈帧计数
    private var warmupFrames = 0              // 启动后先收集若干帧标定基线,期间不触发
    private let warmupTarget = 8
    private var onSpeech: (() -> Void)?
    private var didFire = false

    /// - triggerFrames: 触发所需连续高能帧数(默认 3,约 ~0.2s)
    /// - thresholdFactor: 相对基线倍数(默认 3.0)
    /// - absoluteFloor: 绝对能量地板(默认 0.010)
    init(triggerFrames: Int = 3, thresholdFactor: Float = 3.0, absoluteFloor: Float = 0.010) {
        self.triggerFrames = triggerFrames
        self.thresholdFactor = thresholdFactor
        self.absoluteFloor = absoluteFloor
        super.init()
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    /// 开始监听。检测到一次开口后回调 `onSpeech`(主线程,只回一次),随后自动 `stop()`。
    /// 起不来(无麦克风 / 格式非法)静默返回,不抛错 —— barge-in 是「锦上添花」,失败不该影响主流程。
    func start(onSpeech: @escaping () -> Void) {
        guard !running else { return }
        self.onSpeech = onSpeech
        didFire = false
        hotFrames = 0
        warmupFrames = 0
        baseline = 0.0015

        // iOS:要边播朗读边收麦克风,会话得是可同时播放+录制的 .playAndRecord;
        // 这里用 .mixWithOthers 不打断 TTS 播放,.defaultToSpeaker 保证外放。
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            return
        }
        #endif

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        // tap 在音频线程:只读 buffer 算 RMS、更新原子状态,不碰 SwiftUI。
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            running = true
        } catch {
            input.removeTap(onBus: 0)
            return
        }
    }

    func stop() {
        guard running || engine.isRunning else {
            // 即使没成功 start,tap 也可能挂着 —— 无条件摘一次。
            engine.inputNode.removeTap(onBus: 0)
            return
        }
        running = false
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        onSpeech = nil
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        for i in 0..<n {
            let s = ch[i]
            sum += s * s
        }
        let rms = (sum / Float(n)).squareRoot()

        // 启动预热:先收几帧把基线标到当前环境噪声水平,期间不触发(滤掉刚开 tap 的瞬态)。
        if warmupFrames < warmupTarget {
            warmupFrames += 1
            baseline = baseline * 0.6 + rms * 0.4
            return
        }

        let threshold = max(absoluteFloor, baseline * thresholdFactor)
        if rms > threshold {
            hotFrames += 1
            if hotFrames >= triggerFrames {
                fire()
            }
        } else {
            hotFrames = 0
            // 安静时缓慢自适应基线(只在低能量帧更新,避免把人声并进基线)。
            baseline = baseline * 0.95 + rms * 0.05
        }
    }

    private func fire() {
        // 只回一次。stop() 在主线程做(动 engine 要回主线程,和 SpeechRecognizer 一致)。
        guard !didFire else { return }
        didFire = true
        let cb = onSpeech
        onMain { [weak self] in
            self?.stop()
            cb?()
        }
    }
}
