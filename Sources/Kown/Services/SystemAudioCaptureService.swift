#if os(macOS)
import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// 系统声音捕获(macOS 专属)。用 ScreenCaptureKit 的 `SCStream` 做**纯音频**捕获:
/// 抓的是整机系统播放的声音(Zoom / 腾讯会议里对方的声音、扬声器输出),不是麦克风。
///
/// 设计要点:
/// - `capturesAudio = true`、`excludesCurrentProcessAudio = true`(排除 Kown 自己发出的声音,
///   避免把我们的 TTS / 提示音也录进去);视频配到最小(1×1)且**不消费**视频帧。
/// - CMSampleBuffer(系统给的交错/平面 PCM)→ `AVAudioPCMBuffer`,丢给上层喂 `SFSpeechRecognizer`。
/// - 屏幕录制权限(TCC)被拒时不崩:回调一个可读错误,UI 负责引导去「系统设置 › 隐私与安全性 › 屏幕录制」。
///
/// **并发**:`SCStreamOutput` 的回调在 SCK 自己的队列上触发,本类不隔离到 MainActor;
/// 音频回调里只碰局部转换 + 调用方传入的 `@Sendable` 闭包,状态变更交给调用方派发。
final class SystemAudioCaptureService: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    enum CaptureError: LocalizedError {
        case permissionDenied
        case noDisplay
        case alreadyRunning
        case underlying(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Kown 没有「屏幕录制」权限,无法捕获系统声音。请在系统设置 › 隐私与安全性 › 屏幕录制里勾选 Kown,然后重开会议捕获。"
            case .noDisplay:
                return "找不到可捕获的显示器。"
            case .alreadyRunning:
                return "系统声音捕获已在进行中。"
            case .underlying(let m):
                return m
            }
        }
    }

    /// 系统声音 PCM 回调队列(串行)。
    private let sampleQueue = DispatchQueue(label: "com.kown.system-audio.samples")

    private var stream: SCStream?
    /// 收到一段系统声音 PCM 时回调(在 `sampleQueue` 上)。
    private var onAudio: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// 流意外失败时回调(SCK 主动停流,如用户撤权)。
    private var onStop: (@Sendable (Error) -> Void)?

    private(set) var isRunning = false

    /// 打开系统设置「屏幕录制」面板的 deep link。
    static let screenRecordingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )

    /// 当前是否已有屏幕录制权限(不弹窗;`notDetermined` 也返回 false,真正触发授权在 `start`)。
    static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 启动纯音频捕获。
    /// - onAudio: 每段系统声音 PCM(在后台队列回调)。
    /// - onStop: 流意外终止时回调(用户撤权 / 系统中断)。
    func start(
        onAudio: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onStop: @escaping @Sendable (Error) -> Void
    ) async throws {
        guard !isRunning else { throw CaptureError.alreadyRunning }
        self.onAudio = onAudio
        self.onStop = onStop

        // 没权限时 SCShareableContent 会抛错;先主动触发一次授权请求(首次会弹系统弹窗)。
        if !Self.hasScreenRecordingPermission() {
            // 这是同步调用,会触发系统弹窗(若 notDetermined)。已拒会直接返回 false。
            _ = CGRequestScreenCaptureAccess()
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
        } catch {
            // 权限被拒最典型就在这里抛错。
            throw CaptureError.permissionDenied
        }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        // 过滤器:整个显示器(纯音频不在意捕了哪个屏)。
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // 视频配到最小并尽量低帧:我们不消费视频帧,但 SCStream 仍需要一份视频配置。
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1fps，足够低
        config.queueDepth = 6

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        } catch {
            throw CaptureError.underlying("无法添加音频输出:\(error.localizedDescription)")
        }

        do {
            try await stream.startCapture()
        } catch {
            throw CaptureError.permissionDenied
        }
        self.stream = stream
        self.isRunning = true
    }

    /// 停止捕获(幂等)。
    func stop() async {
        guard let stream else { isRunning = false; return }
        self.stream = nil
        self.isRunning = false
        try? await stream.stopCapture()
        onAudio = nil
        onStop = nil
    }

    // MARK: - SCStreamOutput(音频帧回调,在 sampleQueue 上)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        onAudio?(pcm)
    }

    // MARK: - SCStreamDelegate(流意外终止)

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let wasRunning = isRunning
        isRunning = false
        self.stream = nil
        if wasRunning { onStop?(error) }
    }

    // MARK: - CMSampleBuffer → AVAudioPCMBuffer

    /// 把 SCK 给的音频 `CMSampleBuffer` 转成 `AVAudioPCMBuffer`。
    /// SCK 的系统声音是 Float32、交错或平面,采样率/声道由 stream 配置决定。失败返回 nil(静默丢帧)。
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = sampleBuffer.formatDescription,
              let asbdPtr = formatDesc.audioStreamBasicDescription.map({ $0 }) else {
            return nil
        }
        var asbd = asbdPtr
        guard let avFormat = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frameCount > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: frameCount) else {
            return nil
        }
        pcm.frameLength = frameCount

        // 把样本拷进 PCM buffer 的 audioBufferList。
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcm.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return pcm
    }
}
#endif
