import Foundation

// MARK: - 版本模型

/// Artifact 的一个历史版本。v1 = 模型回答里的原始输出,之后每次「手动保存」或「AI 修改」追加一版。
struct ArtifactVersion: Codable, Identifiable, Hashable, Sendable {
    enum Origin: String, Codable, Sendable {
        case original   // 模型回答里的原始输出(v1)
        case manual     // 用户手动编辑后保存
        case ai         // 「让 AI 修改」产生

        var displayName: String {
            switch self {
            case .original: return "原始"
            case .manual:   return "手动编辑"
            case .ai:       return "AI 修改"
            }
        }
    }

    let id: UUID
    let createdAt: Date
    let origin: Origin
    let source: String

    init(origin: Origin, source: String) {
        self.id = UUID()
        self.createdAt = Date()
        self.origin = origin
        self.source = source
    }
}

/// 「让 AI 修改 artifact」可能的失败。
enum ArtifactRevisionError: LocalizedError {
    case noProvider
    case emptyReply

    var errorDescription: String? {
        switch self {
        case .noProvider: return "没有可用的模型(需要至少启用一个非 CLI 厂商)"
        case .emptyReply: return "模型没有返回可用的代码"
        }
    }
}

// MARK: - 持久化

/// Artifact 版本历史的持久化(Canvas 化的「迭代记录」)。
///
/// 按会话一个 JSON 文件:`artifact-versions/<conversationID>.json`,
/// 内容是 `[artifactKey: [ArtifactVersion]]`;artifactKey = "<turnID>#<blockID>",
/// 即「哪条回答里的第几个 artifact」。放同步根下,随 iCloud 同步,刷新/重开会话后还在。
/// 模式对齐 `ConversationImageStore`(会话附属数据,文件名用 UUID 不撞名)。
@MainActor
enum ArtifactVersionStore {
    /// 单个 artifact 最多保留的版本数(防失控膨胀;超出丢最老的中间版,但 v1 原始永远保留)。
    static let maxVersionsPerArtifact = 30

    /// 内存缓存:convID → (artifactKey → versions)。面板 0.3s tick 频繁查询,不能每次读盘。
    private static var cache: [UUID: [String: [ArtifactVersion]]] = [:]

    static var dir: URL {
        let url = Platform.syncedDataDir.appendingPathComponent("artifact-versions", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700 as NSNumber]
        )
        return url
    }

    private static func fileURL(for conversationID: UUID) -> URL {
        dir.appendingPathComponent("\(conversationID.uuidString).json")
    }

    /// 组合 artifact 的持久化键:回答(turn)id + 该回答里的 artifact 序号。
    static func key(turnID: UUID, blockID: Int) -> String {
        "\(turnID.uuidString)#\(blockID)"
    }

    /// 读某个 artifact 的全部版本(无历史返回空数组)。
    static func versions(conversationID: UUID, key: String) -> [ArtifactVersion] {
        loadAll(conversationID: conversationID)[key] ?? []
    }

    /// 追加一个版本并落盘。`originalSource` 在该 artifact 还没有任何历史时先补一条 v1(原始)。
    static func append(_ version: ArtifactVersion,
                       conversationID: UUID,
                       key: String,
                       originalSource: String) {
        var all = loadAll(conversationID: conversationID)
        var list = all[key] ?? []
        if list.isEmpty {
            list.append(ArtifactVersion(origin: .original, source: originalSource))
        }
        list.append(version)
        // 封顶:保留 v1 + 最近的 (max-1) 个。
        if list.count > maxVersionsPerArtifact {
            let head = list[0]
            list = [head] + list.suffix(maxVersionsPerArtifact - 1)
        }
        all[key] = list
        cache[conversationID] = all
        save(all, conversationID: conversationID)
    }

    // MARK: - Private

    private static func loadAll(conversationID: UUID) -> [String: [ArtifactVersion]] {
        if let cached = cache[conversationID] { return cached }
        var result: [String: [ArtifactVersion]] = [:]
        let url = fileURL(for: conversationID)
        if let data = try? Data(contentsOf: url), !data.isEmpty,
           let decoded = try? JSONDecoder().decode([String: [ArtifactVersion]].self, from: data) {
            result = decoded
        } else {
            // 可能是 iCloud 占位文件:触发下载,本次按空处理,稍后重试自然命中。
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        cache[conversationID] = result
        return result
    }

    private static func save(_ all: [String: [ArtifactVersion]], conversationID: UUID) {
        do {
            let data = try JSONEncoder().encode(all)
            try data.write(to: fileURL(for: conversationID), options: .atomic)
        } catch {
            NSLog("Kown: ArtifactVersionStore save failed: \(error.localizedDescription)")
        }
    }
}
