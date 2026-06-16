#if os(macOS)
import Foundation
import Combine

/// 实时屏幕副驾(macOS 专属)。
///
/// 用户显式开启后,**节流地持续截屏 + 本地 OCR**,把识别到的文字增量喂进一个滚动文本缓冲;
/// 用户随口问「刚那页讲了啥」「总结我刚读的这段」时,把这段 buffer 当上下文交给模型。
///
/// 隐私优先(铁律):
///  - **必须用户显式 start**;停就是停(`stop()` 后捕获循环立刻退出,不留后台任务)。
///  - 全程**本机处理**:截屏 → 本地 Vision OCR → 内存 buffer,**绝不上传截图**,buffer 也不落盘。
///  - UI 有醒目的「正在看屏幕」状态(本类暴露 `isWatching`)。
///
/// 并发取舍:截屏(`ScreenCaptureService.captureMainDisplay`,async)与 OCR(`OCRService`,内部派发后台队列)
/// 本身就在后台跑;本类标 `@MainActor` 只为 `@Published` 安全发布,捕获循环用 `Task`(MainActor)驱动,
/// 每轮 `await` 时主线程让出,重活在 await 的子系统里跑——不阻塞 UI(CPU 卡死前科:重活绝不同步占主线程)。
@MainActor
final class ScreenCopilotService: ObservableObject {
    static let shared = ScreenCopilotService()

    /// 是否正在持续看屏(驱动「正在看屏幕」醒目状态)。
    @Published private(set) var isWatching = false
    /// 滚动文本缓冲(最新在**末尾**)。每段是一次截屏 OCR 的去重结果。
    @Published private(set) var buffer: String = ""
    /// 已累计捕获的帧数(展示用)。
    @Published private(set) var frameCount = 0
    /// 最近一次成功捕获的时间(展示「N 秒前更新」)。
    @Published private(set) var lastCaptureAt: Date?
    /// 最近一次错误(权限被拒等;UI 据此提示并自动停)。
    @Published var lastError: String?

    /// 截屏间隔(秒),可在 2~5 之间;太密既费电又 OCR 跟不上,太疏会漏内容。
    @Published var intervalSeconds: Double = 3 {
        didSet {
            let clamped = min(max(intervalSeconds, 2), 5)
            guard clamped != intervalSeconds else { return }
            intervalSeconds = clamped
        }
    }

    /// buffer 字符上限:超出从头部裁掉(滚动窗口)。约几千字,够「刚读的这段」用,又不至于撑爆上下文。
    private let maxBufferChars = 8000
    /// 单帧 OCR 文本进 buffer 的字符上限(整屏文字可能很多,截一刀防单帧灌爆)。
    private let maxFrameChars = 1500

    /// 捕获循环 Task;`stop()` 时 cancel。
    private var loopTask: Task<Void, Never>?
    /// 上一帧 OCR 文本(连续两帧高度重合时跳过,避免静止画面把同一段刷满 buffer)。
    private var lastFrameText = ""

    private init() {}

    // MARK: - 启停

    /// 开始持续看屏。无权限时先触发系统授权请求并把错误抛给 UI(不崩、不静默)。
    /// 幂等:已在看屏直接返回。
    func start() {
        guard !isWatching else { return }
        guard ScreenCaptureService.hasScreenRecordingPermission() else {
            // 触发一次系统授权(notDetermined 会弹窗),并给 UI 一个可读提示。
            Task.detached { _ = try? await ScreenCaptureService.captureMainDisplay() }
            lastError = ScreenCaptureService.CaptureError.noPermission.errorDescription
            return
        }
        lastError = nil
        isWatching = true
        lastFrameText = ""
        startLoop()
    }

    /// 停止看屏:取消循环 Task,状态归位(buffer 保留,方便停了之后还能问「刚那页」)。
    func stop() {
        loopTask?.cancel()
        loopTask = nil
        isWatching = false
    }

    /// 清空滚动缓冲(用户想「忘掉刚才看的」)。
    func clearBuffer() {
        buffer = ""
        frameCount = 0
        lastFrameText = ""
        lastCaptureAt = nil
    }

    // MARK: - 捕获循环

    private func startLoop() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.captureOnce()
                guard !Task.isCancelled else { break }
                let ns = UInt64(self.intervalSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }

    /// 跑一帧:截屏 → OCR → 去重 → 追加 buffer。任何失败按类型处理:权限类停掉并提示,
    /// 「没识别到文字」属正常(空白画面),静默跳过。
    private func captureOnce() async {
        do {
            let image = try await ScreenCaptureService.captureMainDisplay()
            guard !Task.isCancelled else { return }
            let text: String
            do {
                text = try await OCRService.recognizeText(in: image, orientation: .up)
            } catch {
                // .noText(空白画面 / 纯图)是常态,不当错误;其它 OCR 错误也只跳过这帧。
                lastCaptureAt = Date()
                return
            }
            guard !Task.isCancelled else { return }
            appendFrame(text)
            frameCount += 1
            lastCaptureAt = Date()
        } catch let err as ScreenCaptureService.CaptureError {
            // 权限被拒 / 找不到显示器:停止循环并提示(继续跑只会每隔几秒再弹一次)。
            lastError = err.errorDescription
            stop()
        } catch {
            // 其它偶发错误:跳过这帧,不停整个循环(可能只是一次抓屏抖动)。
        }
    }

    /// 把一帧 OCR 文本去重后追加进滚动 buffer,并把 buffer 裁到上限内。
    private func appendFrame(_ raw: String) {
        var frame = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !frame.isEmpty else { return }
        if frame.count > maxFrameChars { frame = String(frame.prefix(maxFrameChars)) }

        // 与上一帧高度重合(静止画面 / 只滚了一点)时跳过,避免同段反复入 buffer。
        if !lastFrameText.isEmpty, Self.overlapRatio(lastFrameText, frame) > 0.85 { return }
        lastFrameText = frame

        let stamp = Self.timeLabel(Date())
        let entry = "[\(stamp)] \(frame)"
        buffer = buffer.isEmpty ? entry : (buffer + "\n\n" + entry)

        // 滚动裁剪:超上限就从头部丢(保留最新),并对齐到段边界,别把一段切半。
        if buffer.count > maxBufferChars {
            let overflow = buffer.count - maxBufferChars
            var cut = buffer.index(buffer.startIndex, offsetBy: overflow)
            if let para = buffer.range(of: "\n\n", range: cut..<buffer.endIndex) {
                cut = para.upperBound
            }
            buffer = String(buffer[cut...])
        }
    }

    // MARK: - 给模型的上下文

    /// 取最近 buffer 作为提问上下文(`maxChars` 截最新的一段)。空则 nil。
    func contextSnapshot(maxChars: Int = 6000) -> String? {
        let t = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.count <= maxChars { return t }
        // 取末尾最新内容。
        return "…\n" + String(t.suffix(maxChars))
    }

    // MARK: - 工具

    /// 两段文本的字符级粗略重合度(取较短串里有多少比例的字符也在较长串里)。
    /// 只用于「静止画面跳过」的启发式判断,不求精确。
    static func overlapRatio(_ a: String, _ b: String) -> Double {
        let shorter = a.count <= b.count ? a : b
        let longerSet = Set(a.count <= b.count ? b : a)
        guard !shorter.isEmpty else { return 0 }
        var hit = 0
        for ch in shorter where longerSet.contains(ch) { hit += 1 }
        return Double(hit) / Double(shorter.count)
    }

    private static func timeLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
#endif
