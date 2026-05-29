#if os(macOS)
import Foundation

/// Prompt passed via CLI flags or stdin, written to ~/.kown/pending.txt before GUI launches,
/// then consumed once by AppViewModel on startup. macOS only — iOS 没有终端入口。
enum CLIPendingPrompt {
    private static var pendingURL: URL {
        Platform.appDataDir.appendingPathComponent("pending.txt")
    }

    static func store(_ prompt: String) {
        try? prompt.write(to: pendingURL, atomically: true, encoding: .utf8)
    }

    static func consume() -> String? {
        guard let text = try? String(contentsOf: pendingURL, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        try? FileManager.default.removeItem(at: pendingURL)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
