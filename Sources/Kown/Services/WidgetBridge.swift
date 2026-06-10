import Foundation
#if canImport(WidgetKit) && os(iOS)
import WidgetKit
#endif

/// 主 app → iOS 桌面小组件 的数据桥。
///
/// - 写:把「最新晨报摘要」「本月用量/预算」序列化成 JSON 写进 App Group 容器,
///   并 `WidgetCenter.shared.reloadAllTimelines()` 刷新小组件。
/// - 读:Widget 扩展(KownWidgets)把本文件单独加进自己的 sources(见 ios/project.yml),
///   用同一套 Codable 结构 + load 函数读快照。
///
/// 本文件同时被 SwiftPM / mac / iOS 主 app / KownWidgets 扩展编译,因此:
/// - 只 import Foundation(WidgetKit 用 `#if canImport(WidgetKit) && os(iOS)` 守护);
/// - 不引用任何 app 内业务类型(Turn / Conversation 等),入参都是基础类型;
/// - 拿不到 App Group 容器(mac / SwiftPM CLI)时所有写入静默跳过。
enum WidgetBridge {
    static let appGroupID = "group.com.xiaobo.kown"

    // MARK: - 快照结构(app 写,widget 读)

    /// 最近一份晨间简报的摘要快照。
    struct BriefingSnapshot: Codable {
        var title: String
        var points: [String]
        var generatedAt: Date
    }

    /// 本月用量 / 预算快照(给 gauge 小组件)。
    struct BudgetSnapshot: Codable {
        var monthSpendUSD: Double
        /// 0 = 用户未设预算上限。
        var monthlyCapUSD: Double
        var updatedAt: Date
    }

    // MARK: - 容器路径

    private static func snapshotURL(_ name: String) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(name)
    }

    static var briefingURL: URL? { snapshotURL("widget-briefing.json") }
    static var budgetURL: URL? { snapshotURL("widget-budget.json") }

    // MARK: - 读(widget 扩展用)

    static func loadBriefing() -> BriefingSnapshot? {
        guard let url = briefingURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BriefingSnapshot.self, from: data)
    }

    static func loadBudget() -> BudgetSnapshot? {
        guard let url = budgetURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BudgetSnapshot.self, from: data)
    }

    // MARK: - 晨报发布(主 app 用)

    /// 晨报会话登记:SchedulerService 触发晨间简报任务时记下新建会话的 ID,
    /// 等该会话本轮回答完成(AppViewModel+Send 落盘 turn 处)再提取要点发布。
    @MainActor static var pendingBriefingConversationID: UUID?

    /// 回答完成时调用:若是登记过的晨报会话,从回答 markdown 里提取标题+要点写入快照并刷新小组件。
    /// 非晨报会话直接 no-op,所以调用方可以无条件加这一行。
    @MainActor
    static func publishBriefingIfPending(conversationID: UUID, answerMarkdown: String) {
        guard pendingBriefingConversationID == conversationID else { return }
        pendingBriefingConversationID = nil
        let text = answerMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let (title, points) = extractBriefing(markdown: text)
        write(BriefingSnapshot(title: title, points: points, generatedAt: Date()), to: briefingURL)
        reloadTimelines()
    }

    // MARK: - 用量/预算发布(主 app 用)

    @MainActor private static var lastUsagePublish: Date = .distantPast

    /// 用量更新时调用(UsageStore.record 末尾一行)。预算上限直接读 UserDefaults
    /// (与 UsageSettingsView / 预算闸同一 key:`kown.budget.monthlyCapUSD`)。
    /// 60 秒节流,避免连续流式回答每轮都刷新 widget 时间线。
    @MainActor
    static func publishUsage(monthSpendUSD: Double) {
        #if os(iOS)
        guard Date().timeIntervalSince(lastUsagePublish) > 60 else { return }
        lastUsagePublish = Date()
        let cap = UserDefaults.standard.double(forKey: "kown.budget.monthlyCapUSD")
        write(BudgetSnapshot(monthSpendUSD: monthSpendUSD, monthlyCapUSD: cap, updatedAt: Date()),
              to: budgetURL)
        reloadTimelines()
        #endif
    }

    // MARK: - 内部

    private static func write<T: Encodable>(_ value: T, to url: URL?) {
        guard let url, let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func reloadTimelines() {
        #if canImport(WidgetKit) && os(iOS)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// 从晨报 markdown 提取「标题 + 前几条要点」:
    /// - 标题:第一行非空文本(去掉 `#` / `*` 等记号),截断到 40 字;
    /// - 要点:以 `-` / `*` / `•` / `1.` 等开头的行(去掉记号与 `**` 强调),最多 6 条、每条 80 字;
    /// - 没有任何列表行时,退化为取标题后的前几行普通文本。
    static func extractBriefing(markdown: String) -> (title: String, points: [String]) {
        let lines = markdown
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") }

        func clean(_ s: String) -> String {
            var out = s.replacingOccurrences(of: "**", with: "")
            out = out.replacingOccurrences(of: "`", with: "")
            return out.trimmingCharacters(in: .whitespaces)
        }
        func stripBullet(_ s: String) -> String? {
            for prefix in ["- ", "* ", "• "] where s.hasPrefix(prefix) {
                return clean(String(s.dropFirst(prefix.count)))
            }
            // "1." / "2、" / "3)" 等编号
            if let first = s.first, first.isNumber {
                let rest = s.drop(while: { $0.isNumber })
                if let mark = rest.first, ".、)）".contains(mark) {
                    return clean(String(rest.dropFirst()))
                }
            }
            return nil
        }

        var title = "今日晨报"
        if let firstLine = lines.first {
            let t = clean(firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
            if !t.isEmpty { title = String(t.prefix(40)) }
        }

        var points: [String] = []
        for line in lines.dropFirst() {
            if let p = stripBullet(line), !p.isEmpty {
                points.append(String(p.prefix(80)))
                if points.count >= 6 { break }
            }
        }
        if points.isEmpty {
            points = lines.dropFirst().prefix(4).map { String(clean($0).prefix(80)) }
        }
        return (title, points)
    }
}
