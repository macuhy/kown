import Foundation
import Combine

/// 收藏的回答片段。随 iCloud 同步(存 syncedDataDir/favorites.json)。
struct FavoriteSnippet: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var text: String
    var providerName: String
    var model: String
    var createdAt: Date

    init(id: UUID = UUID(), text: String, providerName: String, model: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.providerName = providerName
        self.model = model
        self.createdAt = createdAt
    }
}

/// 答案收藏夹 / 片段库。单例,卡片 footer 与设置页共享(同 SpeechService.shared 模式)。
@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    @Published private(set) var items: [FavoriteSnippet] = []

    private var url: URL { Platform.syncedDataDir.appendingPathComponent("favorites.json") }

    private init() { reload() }

    func reload() {
        items = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([FavoriteSnippet].self, from: $0) } ?? []
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: url, options: .atomic) }
    }

    private func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    func contains(_ text: String) -> Bool {
        let t = norm(text)
        guard !t.isEmpty else { return false }
        return items.contains { norm($0.text) == t }
    }

    /// 收藏 / 取消收藏(按正文判重)。
    func toggle(text: String, providerName: String, model: String) {
        let t = norm(text)
        guard !t.isEmpty else { return }
        if let i = items.firstIndex(where: { norm($0.text) == t }) {
            items.remove(at: i)
        } else {
            items.insert(FavoriteSnippet(text: text, providerName: providerName, model: model), at: 0)
        }
        persist()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
    }
}
