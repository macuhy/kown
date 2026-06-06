import Foundation

/// 一条「定时 / 周期任务」:把一段固定的 prompt 在每天指定时刻自动发出,
/// 结果落成一个新会话,并发一条本地通知提醒用户。
///
/// **重要:仅在 app 运行(前台或被系统短暂保活)期间发火** —— 后台常驻定时执行受 OS 限制
/// (macOS 可后台跑,iOS 被 suspend 后定时器停摆),所以本功能定位为「打开 app 时补跑当天该跑的任务」。
struct ScheduledTask: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    /// 任务名(列表展示用)。
    var title: String
    /// 要发送的 prompt 正文。
    var prompt: String
    /// 用哪个对话模式发(council / direct / compare / debate / structured)。
    var mode: ConversationMode
    /// 触发时刻 — 小时(0...23)。
    var hour: Int
    /// 触发时刻 — 分钟(0...59)。
    var minute: Int
    /// 每天重复。当前实现固定为按天重复(预留位,关掉后即一次性任务)。
    var repeatsDaily: Bool
    /// 是否启用(关掉后不发火)。
    var enabled: Bool
    /// 上次实际发火的时间(用于「当天已跑过就不再重复」判断)。
    var lastRun: Date?

    init(
        id: UUID = UUID(),
        title: String = "",
        prompt: String = "",
        mode: ConversationMode = .direct,
        hour: Int = 9,
        minute: Int = 0,
        repeatsDaily: Bool = true,
        enabled: Bool = true,
        lastRun: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.mode = mode
        self.hour = hour
        self.minute = minute
        self.repeatsDaily = repeatsDaily
        self.enabled = enabled
        self.lastRun = lastRun
    }

    // 兼容旧 JSON(缺字段容错,避免整份解码失败丢任务)。
    enum CodingKeys: String, CodingKey {
        case id, title, prompt, mode, hour, minute, repeatsDaily, enabled, lastRun
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        self.mode = try c.decodeIfPresent(ConversationMode.self, forKey: .mode) ?? .direct
        self.hour = try c.decodeIfPresent(Int.self, forKey: .hour) ?? 9
        self.minute = try c.decodeIfPresent(Int.self, forKey: .minute) ?? 0
        self.repeatsDaily = try c.decodeIfPresent(Bool.self, forKey: .repeatsDaily) ?? true
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.lastRun = try c.decodeIfPresent(Date.self, forKey: .lastRun)
    }

    /// 触发时刻的展示文本,如 `09:05`。
    var timeText: String {
        String(format: "%02d:%02d", hour, minute)
    }
}

/// 定时任务列表持久化:`syncedDataDir/scheduled-tasks.json`(随 iCloud 同步)。
/// 同 `ConversationFolderStore` 的 @MainActor + JSONEncoder + .atomic 模式。
@MainActor
enum ScheduledTaskStore {
    private static var url: URL {
        Platform.syncedDataDir.appendingPathComponent("scheduled-tasks.json")
    }

    static func load() -> [ScheduledTask] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([ScheduledTask].self, from: data) else { return [] }
        return list
    }

    static func save(_ tasks: [ScheduledTask]) {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
