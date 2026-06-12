import Foundation
import Vision
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// OCR 文字识别(跨平台)。用 Vision 的 `VNRecognizeTextRequest` 从图片里提取文字。
/// 识别语言固定中文简体 + 英文,开启语言纠错;按视觉行序拼接结果。
enum OCRService {

    enum OCRError: LocalizedError {
        case invalidImage          // 拿不到 CGImage(无法送进 Vision)
        case noText                // 识别成功但没找到任何文字

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "无法读取该图片"
            case .noText:       return "没有在图片里识别到文字"
            }
        }
    }

    /// 核心:对一张 `CGImage` 做文字识别,返回拼好的多行文本。两平台共用。
    static func recognizeText(in cgImage: CGImage, orientation: CGImagePropertyOrientation = .up) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(throwing: OCRError.noText)
                    return
                }
                // 每个观测取最优候选,按观测顺序(Vision 已按视觉行序返回)拼成多行文本。
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    continuation.resume(throwing: OCRError.noText)
                } else {
                    continuation.resume(returning: text)
                }
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true

            // Vision 请求是同步阻塞的,丢到后台队列避免卡主线程。
            DispatchQueue.global(qos: .userInitiated).async {
                let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 聊天转录识别(按气泡左右位置区分发言人)

    /// 聊天截图/窗口里识别出的一条消息。
    struct ChatMessage: Sendable {
        enum Side: Sendable { case me, other }
        let side: Side
        var text: String
    }

    /// Vision 回调里就地提取的一行(observation 本身非 Sendable,不能跨隔离带出来)。
    private struct ChatLine: Sendable {
        let text: String
        let box: CGRect
        let side: ChatMessage.Side
    }

    /// 对聊天界面的图片做「带发言人」的识别:
    /// 聊天 app 通行布局是 对方气泡靠左、自己的气泡靠右,据此把每个文本块归边;
    /// 基本居中的(时间戳、撤回提示)跳过;同侧纵向相邻的行合并成一条消息。
    /// 一条带边的消息都没有(不是聊天界面)时抛 `noText`,调用方可回退平铺 OCR。
    static func recognizeChatMessages(in cgImage: CGImage,
                                      orientation: CGImagePropertyOrientation = .up) async throws -> [ChatMessage] {
        let lines: [ChatLine] = try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                // 在回调里就地归边:bbox 是归一化坐标(Vision 原点在左下)。
                var lines: [ChatLine] = []
                for obs in observations {
                    guard let candidate = obs.topCandidates(1).first, candidate.confidence > 0.3 else { continue }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let box = obs.boundingBox
                    let leftGap = box.minX
                    let rightGap = 1 - box.maxX
                    // 两边距离差太小视为居中(时间戳「昨天 14:32」、撤回/入群提示),不算发言。
                    guard abs(leftGap - rightGap) > 0.08 else { continue }
                    lines.append(ChatLine(text: text, box: box, side: leftGap < rightGap ? .other : .me))
                }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true
            DispatchQueue.global(qos: .userInitiated).async {
                let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        guard !lines.isEmpty else { throw OCRError.noText }

        // 顶部 → 底部排序后,同侧、纵向间距小于约 1.2 行高的行合并(长气泡内自动换行)。
        var sorted = lines
        sorted.sort { $0.box.maxY > $1.box.maxY }
        var messages: [ChatMessage] = []
        var lastBottom: CGFloat = .greatestFiniteMagnitude
        for line in sorted {
            let gap = lastBottom - line.box.maxY
            let lineHeight = max(line.box.height, 0.012)
            if var last = messages.last, last.side == line.side, gap < lineHeight * 1.2 {
                last.text += line.text
                messages[messages.count - 1] = last
            } else {
                messages.append(ChatMessage(side: line.side, text: line.text))
            }
            lastBottom = line.box.minY
        }
        return messages
    }

    /// 把消息列表拼成给模型看的转录文本(「我:/对方:」逐行)。
    static func chatTranscript(_ messages: [ChatMessage]) -> String {
        messages.map { ($0.side == .me ? "我: " : "对方: ") + $0.text }
            .joined(separator: "\n")
    }

    #if os(iOS)
    /// iOS:对一张 `UIImage` 做识别(保留 EXIF 旋转)。
    static func recognizeText(in image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else { throw OCRError.invalidImage }
        return try await recognizeText(in: cgImage, orientation: image.cgImageOrientation)
    }

    /// iOS:对聊天截图做带发言人的识别(保留 EXIF 旋转)。
    static func recognizeChatMessages(in image: UIImage) async throws -> [ChatMessage] {
        guard let cgImage = image.cgImage else { throw OCRError.invalidImage }
        return try await recognizeChatMessages(in: cgImage, orientation: image.cgImageOrientation)
    }
    #elseif os(macOS)
    /// macOS:对一张 `NSImage` 做识别。
    static func recognizeText(in image: NSImage) async throws -> String {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw OCRError.invalidImage
        }
        return try await recognizeText(in: cgImage, orientation: .up)
    }
    #endif
}

#if os(iOS)
private extension UIImage {
    /// 把 `UIImage.imageOrientation` 映射成 Vision/CoreImage 用的 `CGImagePropertyOrientation`,
    /// 否则相机/相册里带 EXIF 旋转的照片会被横着识别,准确率骤降。
    var cgImageOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up:            return .up
        case .down:          return .down
        case .left:          return .left
        case .right:         return .right
        case .upMirrored:    return .upMirrored
        case .downMirrored:  return .downMirrored
        case .leftMirrored:  return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default:    return .up
        }
    }
}
#endif
