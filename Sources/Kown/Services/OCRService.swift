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

    #if os(iOS)
    /// iOS:对一张 `UIImage` 做识别(保留 EXIF 旋转)。
    static func recognizeText(in image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else { throw OCRError.invalidImage }
        return try await recognizeText(in: cgImage, orientation: image.cgImageOrientation)
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
