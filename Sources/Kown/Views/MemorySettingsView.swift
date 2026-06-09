import SwiftUI

/// 设置 ▸ 记忆:跨会话长期记忆管理。
/// - 注入开关(默认关,隐私优先):开后发送时回灌相关记忆 + 会话结束后抽取新记忆。
/// - 浏览 / 单条删除 / 清空已沉淀的记忆。
/// - 手动添加一条记忆。
struct MemorySettingsView: View {
    @Bindable var viewModel: AppViewModel
    private var store = MemoryStore.shared

    @State private var confirmClear = false
    @State private var newMemoryText = ""

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                toggleCard
                addCard
                listSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .confirmationDialog("清空全部长期记忆?不可恢复。", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { store.clear() }
            Button("取消", role: .cancel) { }
        }
    }

    // MARK: - 注入开关

    private var toggleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $viewModel.memoryInjectionEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("启用跨会话长期记忆")
                        .font(.callout.weight(.semibold))
                    Text("开启后:发送时把相关的长期记忆注入上下文,并在会话进行中自动抽取新的长期记忆。默认关闭(隐私优先)。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !viewModel.memoryInjectionEnabled {
                Label("当前关闭:不会注入,也不会抽取新记忆。已存的记忆保留,可在下方查看 / 删除。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider().padding(.vertical, 2)
            Toggle(isOn: $viewModel.recallEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("启用跨对话语义召回")
                        .font(.callout.weight(.semibold))
                    Text("开启后:发送时自动从你过去的会话里捞与当前问题相关的片段,作为参考注入上下文。默认关闭(隐私优先)。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    // MARK: - 手动添加

    private var addCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("手动添加一条记忆")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("如:我偏好简洁、直接的回答", text: $newMemoryText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addManual)
                Button {
                    addManual()
                } label: {
                    Label("添加", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func addManual() {
        let text = newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.add(text: text)
        newMemoryText = ""
    }

    // MARK: - 列表

    @ViewBuilder
    private var listSection: some View {
        if store.items.isEmpty {
            emptyState
        } else {
            HStack {
                Text("\(store.items.count) / \(MemoryStore.maxItems) 条记忆")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) { confirmClear = true } label: {
                    Label("清空", systemImage: "trash").font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(store.items) { item in row(item) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "brain")
                .font(.system(size: 30, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 62, height: 62)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text("还没有长期记忆").font(.headline.weight(.bold))
            Text("开启上方开关后,会话进行中会自动沉淀长期有用的事实与偏好;也可以在上面手动添加。")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func row(_ item: MemoryItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "brain").font(.caption2).foregroundStyle(.purple)
                if item.sourceConversationID == nil {
                    Text("手动").font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Text(Self.dateFmt.string(from: item.createdAt)).font(.caption2).foregroundStyle(.tertiary)
            }
            Text(item.text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Button(role: .destructive) { store.remove(item.id) } label: {
                    Label("删除", systemImage: "trash").font(.caption2.weight(.semibold)).foregroundStyle(.red)
                }.buttonStyle(.borderless)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }
}
