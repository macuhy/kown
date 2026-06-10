import AppIntents
import Foundation

/// 「存到 Kown 知识库」:把一段文本沉淀为知识库文档(后台运行,不拉起前台 UI)。
/// 复用 `KnowledgeStore` 落盘路径,与 app 内知识库共用同一份 `folders.json`;
/// 写完广播 `kownKnowledgeDidChangeExternally`,app 进程存活时 AppViewModel 会重读内存状态。
struct SaveToKnowledgeIntent: AppIntent {
    static var title: LocalizedStringResource { "存到 Kown 知识库" }
    static var description: IntentDescription {
        IntentDescription("把文本保存为 Kown 知识库文档,之后对话可绑定该资料夹做本地检索。不填资料夹时存入「快捷指令收集」。")
    }

    @Parameter(title: "内容")
    var text: String

    @Parameter(title: "标题")
    var docTitle: String?

    @Parameter(title: "资料夹")
    var folderName: String?

    static var parameterSummary: some ParameterSummary {
        Summary("把 \(\.$text) 存入知识库") {
            \.$docTitle
            \.$folderName
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KownIntentError.emptyInput("没有要保存的内容,请先传入文字。")
        }
        let (folder, doc) = await Self.save(text: trimmed, title: docTitle, folderName: folderName)
        return .result(dialog: IntentDialog("已存入知识库「\(folder)」:\(doc)"))
    }

    /// 落盘:按名字找资料夹(没有就新建),追加文档并保存。返回 (资料夹名, 文档名)。
    @MainActor
    private static func save(text: String, title: String?, folderName: String?) -> (folder: String, doc: String) {
        var folders = KnowledgeStore.loadAll()
        let targetName = normalized(folderName) ?? "快捷指令收集"
        let idx: Int
        if let found = folders.firstIndex(where: { $0.name == targetName }) {
            idx = found
        } else {
            folders.append(KnowledgeFolder(name: targetName))
            idx = folders.count - 1
        }
        let docName = normalized(title) ?? defaultTitle(for: text)
        folders[idx].docs.append(KnowledgeDoc(name: docName, text: text))
        folders[idx].updatedAt = Date()
        KnowledgeStore.saveAll(folders)
        NotificationCenter.default.post(name: .kownKnowledgeDidChangeExternally, object: nil)
        return (targetName, docName)
    }

    private static func normalized(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// 没给标题时:取正文第一行(截到 30 字),空行兜底用时间戳。
    private static func defaultTitle(for text: String) -> String {
        if let firstLine = text
            .components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) {
            return String(firstLine.prefix(30))
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "快捷指令 \(f.string(from: Date()))"
    }
}
