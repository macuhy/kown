import Foundation

/// 一条命名的 Prompt 模板。正文里用 `{{变量}}` 占位符,渲染时按名字替换。
struct PromptTemplate: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         title: String,
         body: String,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 正文里出现的全部 `{{变量}}` 名(去重、保持首次出现顺序)。
    var variableNames: [String] {
        PromptLibraryStore.extractVariables(from: body)
    }
}

/// Prompt 库 / 模板的持久化与增删改查。
///
/// 存盘沿用其它 Service(ConversationStore / UsageStore)的约定:
/// 写到 Application Support 下 App 专属子目录里的一个 JSON 文件,JSONEncoder/JSONDecoder 编解码,
/// 日期用 `.iso8601`。不另起 iCloud 容器路径。
@Observable
final class PromptLibraryStore {
    private(set) var templates: [PromptTemplate] = []

    /// App 在 Application Support 下的专属子目录(与其它本地存盘同一处)。
    private let storeURL: URL

    init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("Kown", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storeURL = dir.appendingPathComponent("prompt_library.json")
        load()
    }

    // MARK: - 增删改查

    /// 新建一条模板,返回新建对象(已落盘)。
    @discardableResult
    func add(title: String, body: String) -> PromptTemplate {
        let template = PromptTemplate(title: title, body: body)
        templates.insert(template, at: 0)
        save()
        return template
    }

    /// 更新一条已存在的模板(按 id 匹配),刷新 updatedAt。
    func update(_ template: PromptTemplate) {
        guard let idx = templates.firstIndex(where: { $0.id == template.id }) else { return }
        var updated = template
        updated.updatedAt = Date()
        templates[idx] = updated
        save()
    }

    /// 删除指定模板。
    func remove(_ template: PromptTemplate) {
        templates.removeAll { $0.id == template.id }
        save()
    }

    /// 删除指定下标(列表里 onDelete 用)。
    func remove(atOffsets offsets: IndexSet) {
        templates.remove(atOffsets: offsets)
        save()
    }

    // MARK: - 渲染

    /// 把模板正文里的 `{{变量}}` 用 values 填充。未提供的变量保留原样占位符。
    func render(_ template: PromptTemplate, values: [String: String]) -> String {
        render(template: template.body, values: values)
    }

    /// 把任意带 `{{变量}}` 的文本用 values 填充。未提供的变量保留原样占位符。
    func render(template body: String, values: [String: String]) -> String {
        var result = body
        for name in Self.extractVariables(from: body) {
            guard let value = values[name] else { continue }
            result = result.replacingOccurrences(of: "{{\(name)}}", with: value)
        }
        return result
    }

    /// 从文本里抽出全部 `{{变量}}` 名(去重、保持首次出现顺序、去掉首尾空白)。
    static func extractVariables(from body: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "\\{\\{\\s*([^{}]+?)\\s*\\}\\}") else {
            return []
        }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        var seen = Set<String>()
        var names: [String] = []
        regex.enumerateMatches(in: body, range: range) { match, _, _ in
            guard let match, match.numberOfRanges >= 2,
                  let r = Range(match.range(at: 1), in: body) else { return }
            let name = String(body[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !seen.contains(name) else { return }
            seen.insert(name)
            names.append(name)
        }
        return names
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([PromptTemplate].self, from: data) else { return }
        templates = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(templates) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
