import Foundation

/// 已发送 prompt 的历史回溯 —— 环形缓冲(最近 N 条)+ JSON 持久化,供输入框 ↑/↓ 调取最近输入。
///
/// 文件放在 `[syncedDataDir]/prompt_history.json`(沿用 ConversationStore / KeychainStore 等同一存盘根,
/// 默认本地 `~/.kown`,iCloud 同步开启时随容器走)。
///
/// 设计要点:
/// - 只在「发送」时入栈;相邻重复(连续两次发一样的)不重复记录,贴合终端 history 体感。
/// - 容量上限 `maxEntries`,超出从最旧一端丢弃(环形)。
/// - 浏览游标(browseIndex)只活在内存里,不持久化:nil = 没在浏览(停在输入框现状)。
@MainActor
@Observable
final class PromptHistoryStore {
    /// 最近发送过的 prompt,新的在末尾(index 越大越新)。
    private(set) var entries: [String]

    /// 环形缓冲容量上限。
    private let maxEntries: Int

    /// 浏览游标 —— 指向 entries 里当前展示的那条;nil 表示没在浏览历史(回到用户原始输入态)。
    private var browseIndex: Int?

    /// 进入浏览前用户已经打了一半的草稿 —— 浏览到底(↓ 越过最新一条)时还原回去。
    private var draftBeforeBrowsing: String?

    static var fileURL: URL {
        Platform.syncedDataDir.appendingPathComponent("prompt_history.json")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted]
        return e
    }()

    init(maxEntries: Int = 50) {
        self.maxEntries = max(1, maxEntries)
        self.entries = Self.load()
    }

    // MARK: - 写入

    /// 把一条已发送的 prompt 记进历史。空白 / 与最近一条相邻重复 → 不记。
    /// 任何一次发送都意味着「浏览结束」,顺手重置游标。
    func record(_ raw: String) {
        resetBrowsing()
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if entries.last == text { return }   // 去重相邻重复
        entries.append(text)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)   // 环形:丢最旧
        }
        persist()
    }

    // MARK: - 浏览(↑/↓)

    /// 用户一开始打字就调用 —— 退出浏览态,后续 ↑ 从最新一条重新开始。
    func resetBrowsing() {
        browseIndex = nil
        draftBeforeBrowsing = nil
    }

    /// 当前是否正处于浏览历史的状态。
    var isBrowsing: Bool { browseIndex != nil }

    /// ↑ 取更早一条。`current` 是输入框现状(用于首次进入浏览时暂存草稿)。
    /// 返回应填入输入框的文本;nil 表示没有可回溯的内容(历史为空 / 已到最旧)。
    func older(current: String) -> String? {
        guard !entries.isEmpty else { return nil }
        switch browseIndex {
        case nil:
            // 首次进入浏览:暂存草稿,跳到最新一条
            draftBeforeBrowsing = current
            browseIndex = entries.count - 1
        case .some(let idx):
            guard idx > 0 else { return nil }   // 已经在最旧一条
            browseIndex = idx - 1
        }
        return browseIndex.map { entries[$0] }
    }

    /// ↓ 取更晚一条。越过最新一条时回到进入浏览前的草稿,并退出浏览态。
    /// 返回应填入输入框的文本;nil 表示当前没在浏览(不应拦截 ↓)。
    func newer() -> String? {
        guard let idx = browseIndex else { return nil }
        if idx < entries.count - 1 {
            browseIndex = idx + 1
            return entries[idx + 1]
        }
        // 已在最新一条,再按 ↓ → 还原草稿、退出浏览
        let draft = draftBeforeBrowsing ?? ""
        resetBrowsing()
        return draft
    }

    // MARK: - 持久化

    private static func load() -> [String] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return list
    }

    private func persist() {
        guard let data = try? Self.encoder.encode(entries) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
