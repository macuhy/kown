import Foundation
#if os(iOS)
import AVFoundation
import UIKit
#endif

/// iOS 流式时播一段循环的**无声** PCM,触发 `UIBackgroundModes: audio`,
/// 让 app 切到后台 / 锁屏后仍持有网络连接,SSE 不被系统 kill。
/// 流结束/失败/取消时必须 `stop()`,否则一直占着音频会话(虽然听不到)。
/// macOS 上整段 no-op。
@MainActor
final class BackgroundAudioKeepalive {
    static let shared = BackgroundAudioKeepalive()

    #if os(iOS)
    private var player: AVAudioPlayer?
    #endif

    func start() {
        #if os(iOS)
        guard player == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // .playback + .mixWithOthers → 不打断用户正在听的音乐/播客
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])
            let data = Self.makeSilenceWAV(seconds: 1.0)
            let p = try AVAudioPlayer(data: data)
            p.numberOfLoops = -1
            p.volume = 0
            p.prepareToPlay()
            p.play()
            player = p
        } catch {
            // 静默失败 — 后台保活只是 best-effort,失败不能阻塞业务
        }
        #endif
    }

    func stop() {
        #if os(iOS)
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    #if os(iOS)
    /// 在内存里手搓一段 1 秒静音的 WAV(16-bit PCM mono 8kHz),约 16KB,不用 bundle 文件。
    private static func makeSilenceWAV(seconds: Double, sampleRate: Double = 8000) -> Data {
        let numSamples = Int(seconds * sampleRate)
        let bytesPerSample = 2
        let dataSize = numSamples * bytesPerSample
        var data = Data()
        func append32(_ v: UInt32) { var le = v.littleEndian; data.append(Data(bytes: &le, count: 4)) }
        func append16(_ v: UInt16) { var le = v.littleEndian; data.append(Data(bytes: &le, count: 2)) }

        data.append("RIFF".data(using: .ascii)!)
        append32(UInt32(36 + dataSize))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        append32(16)               // PCM subchunk size
        append16(1)                // PCM format
        append16(1)                // 1 channel
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))   // byte rate
        append16(2)                // block align
        append16(16)               // bits per sample
        data.append("data".data(using: .ascii)!)
        append32(UInt32(dataSize))
        data.append(Data(count: dataSize))
        return data
    }
    #endif
}
