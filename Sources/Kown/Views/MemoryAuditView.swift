import SwiftUI

/// 设置 ▸ 记忆审计:看长期记忆是否可回溯、是否重复、是否过旧、是否接近容量上限。
struct MemoryAuditView: View {
    @Bindable var viewModel: AppViewModel
    private var store = MemoryStore.shared

    @State private var dedupRunning = false
    @State private var dedupMessage: String?

    private let tint = Color(red: 0.46, green: 0.38, blue: 0.82)

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    private var dedupPlan: (removeIDs: Set<UUID>, pinIDs: Set<UUID>) {
        MemoryStore.dedupPlan(items: store.items)
    }

    private var duplicateItems: [MemoryItem] {
        store.items.filter { dedupPlan.removeIDs.contains($0.id) }
    }

    private var sourceGapItems: [MemoryItem] {
        store.items.filter { $0.sourceConversationID == nil }
    }

    private var staleItems: [MemoryItem] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? .distantPast
        return store.items.filter { $0.createdAt < cutoff && !$0.pinned }
    }

    private var orphanItems: [MemoryItem] {
        let personaIDs = Set(viewModel.personaStore.personas.map(\.id))
        return store.items.filter { item in
            guard let personaID = item.personaID else { return false }
            return !personaIDs.contains(personaID)
        }
    }

    private var globalCount: Int {
        store.items.filter { $0.personaID == nil }.count
    }

    private var personaOwnedCount: Int {
        store.items.count - globalCount
    }

    private var pinnedCount: Int {
        store.items.filter(\.pinned).count
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                header
                metrics
                healthCards
                ownerBreakdown
                duplicateSection
                sourceGapSection
                staleSection
                orphanSection
                if store.items.isEmpty {
                    emptyState
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("记忆审计")
                        .font(.title2.weight(.black))
                    Text("检查长期记忆的来源、归属、重复和过期风险。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    store.reload()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private var metrics: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                metric("总记忆", value: store.items.count, icon: "brain", color: tint)
                metric("置顶", value: pinnedCount, icon: "pin.fill", color: .orange)
                metric("Persona", value: personaOwnedCount, icon: "person.text.rectangle", color: .blue)
                metric("可优化", value: optimizationCount, icon: "wand.and.stars", color: optimizationCount > 0 ? .red : .green)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                metric("总记忆", value: store.items.count, icon: "brain", color: tint)
                metric("置顶", value: pinnedCount, icon: "pin.fill", color: .orange)
                metric("Persona", value: personaOwnedCount, icon: "person.text.rectangle", color: .blue)
                metric("可优化", value: optimizationCount, icon: "wand.and.stars", color: optimizationCount > 0 ? .red : .green)
            }
        }
    }

    private var optimizationCount: Int {
        duplicateItems.count + sourceGapItems.count + staleItems.count + orphanItems.count
    }

    private func metric(_ title: String, value: Int, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)")
                    .font(.headline.weight(.black))
                    .monospacedDigit()
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(Color.platformControlBackground.opacity(0.56), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private var healthCards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .top)], spacing: 12) {
            healthCard(
                title: "容量",
                value: "\(store.items.count) / \(MemoryStore.maxItems)",
                detail: store.items.count >= Int(Double(MemoryStore.maxItems) * 0.85) ? "接近上限,建议清理未置顶旧记忆。" : "容量健康。",
                icon: "externaldrive",
                color: store.items.count >= Int(Double(MemoryStore.maxItems) * 0.85) ? .orange : .green
            )
            healthCard(
                title: "重复",
                value: "\(duplicateItems.count)",
                detail: duplicateItems.isEmpty ? "没有发现近重复条目。" : "可一键合并,置顶状态会继承。",
                icon: "square.on.square",
                color: duplicateItems.isEmpty ? .green : .orange
            )
            healthCard(
                title: "来源缺口",
                value: "\(sourceGapItems.count)",
                detail: sourceGapItems.isEmpty ? "所有记忆都有会话来源。" : "旧数据或手动添加的记忆无法回溯来源。",
                icon: "link",
                color: sourceGapItems.isEmpty ? .green : .orange
            )
            healthCard(
                title: "90 天未更新",
                value: "\(staleItems.count)",
                detail: staleItems.isEmpty ? "没有明显过期的未置顶记忆。" : "建议复核是否仍代表你的偏好或事实。",
                icon: "clock.arrow.circlepath",
                color: staleItems.isEmpty ? .green : .orange
            )
        }
    }

    private func healthCard(title: String, value: String, detail: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(value)
                .font(.title3.weight(.black))
                .monospacedDigit()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private var ownerBreakdown: some View {
        section(title: "归属分布", icon: "person.3.fill", color: tint) {
            VStack(alignment: .leading, spacing: 8) {
                ownerRow(title: "全局记忆", count: globalCount, icon: "globe", color: .green)
                ForEach(viewModel.personaStore.personas) { persona in
                    let count = store.items.filter { $0.personaID == persona.id }.count
                    if count > 0 {
                        ownerRow(title: persona.name.isEmpty ? "未命名 Persona" : persona.name, count: count, icon: "person.text.rectangle", color: .blue)
                    }
                }
                if !orphanItems.isEmpty {
                    ownerRow(title: "已删除 Persona", count: orphanItems.count, icon: "person.slash", color: .orange)
                }
            }
        }
    }

    private func ownerRow(title: String, count: Int, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 22)
            Text(title)
                .font(.callout.weight(.semibold))
            Spacer()
            Text("\(count)")
                .font(.caption.weight(.black))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var duplicateSection: some View {
        if !duplicateItems.isEmpty {
            section(title: "近重复记忆", icon: "square.on.square", color: .orange) {
                HStack {
                    Text("发现 \(duplicateItems.count) 条可合并记忆。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(dedupRunning ? "去重中…" : "一键去重") {
                        runDedup()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(dedupRunning)
                }
                if let dedupMessage {
                    Label(dedupMessage, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(duplicateItems.prefix(8)) { item in
                    auditRow(item, reason: "近重复", color: .orange)
                }
            }
        }
    }

    @ViewBuilder
    private var sourceGapSection: some View {
        if !sourceGapItems.isEmpty {
            section(title: "来源缺口", icon: "link.badge.plus", color: .orange) {
                ForEach(sourceGapItems.prefix(8)) { item in
                    auditRow(item, reason: "无来源", color: .orange)
                }
            }
        }
    }

    @ViewBuilder
    private var staleSection: some View {
        if !staleItems.isEmpty {
            section(title: "建议复核的旧记忆", icon: "clock.arrow.circlepath", color: .orange) {
                ForEach(staleItems.prefix(8)) { item in
                    auditRow(item, reason: "90 天未更新", color: .orange)
                }
            }
        }
    }

    @ViewBuilder
    private var orphanSection: some View {
        if !orphanItems.isEmpty {
            section(title: "已删除 Persona 的遗留记忆", icon: "person.slash", color: .red) {
                ForEach(orphanItems.prefix(8)) { item in
                    auditRow(item, reason: "归属失效", color: .red)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "brain")
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(.secondary)
            Text("还没有长期记忆")
                .font(.headline)
            Text("开启长期记忆后,这里会帮助你审计归属、来源和重复项。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func section<Content: View>(
        title: String,
        icon: String,
        color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline.weight(.bold))
                .foregroundStyle(color)
            content()
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func auditRow(_ item: MemoryItem, reason: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(reason)
                        .font(.caption2.weight(.black))
                        .foregroundStyle(color)
                    if item.pinned {
                        Label("置顶", systemImage: "pin.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.orange)
                    }
                    Text(relativeDate(item.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(item.text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ownerLabel(for: item))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(spacing: 6) {
                Button {
                    store.setPinned(item.id, !item.pinned)
                } label: {
                    Image(systemName: item.pinned ? "pin.slash" : "pin")
                }
                .buttonStyle(.borderless)
                .help(item.pinned ? "取消置顶" : "置顶")

                Button(role: .destructive) {
                    store.remove(item.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除")
            }
        }
        .padding(11)
        .background(Color.platformControlBackground.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func ownerLabel(for item: MemoryItem) -> String {
        guard let personaID = item.personaID else { return "全局记忆" }
        if let persona = viewModel.personaStore.persona(id: personaID) {
            return "Persona: \(persona.name.isEmpty ? "未命名" : persona.name)"
        }
        return "已删除 Persona"
    }

    private func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func runDedup() {
        dedupRunning = true
        dedupMessage = nil
        Task {
            let removed = await store.deduplicate()
            dedupMessage = removed == 0 ? "没有可合并的重复记忆" : "已合并 \(removed) 条重复记忆"
            dedupRunning = false
        }
    }
}
