import SwiftUI

struct SidebarView: View {
    @Bindable var viewModel: AppViewModel
    let onOpenSettings: () -> Void
    var onSelectConversation: () -> Void = {}
    @State private var renamingID: UUID?
    @State private var renameDraft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
            list
        }
        .frame(minWidth: 240)
        .background(sidebarBackdrop)
    }

    private var header: some View {
        #if os(iOS)
        mobileHeader
        #else
        desktopHeader
        #endif
    }

    private var desktopHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.92), Color.orange.opacity(0.68)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)
            .shadow(color: Color.accentColor.opacity(0.18), radius: 12, x: 0, y: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text("All Conversations")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                Text("\(viewModel.conversations.count) 个会话")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            #if os(iOS)
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("厂商配置")
            #endif
            Button {
                viewModel.newConversation(mode: viewModel.activeMode)
                onSelectConversation()
            } label: {
                Image(systemName: "square.and.pencil")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("新建会话")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.thinMaterial)
    }

    #if os(iOS)
    private var mobileHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [currentModeTint.opacity(0.95), Color.orange.opacity(0.70)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "bubble.left.and.text.bubble.right.fill")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(.white)
                }
                .frame(width: 46, height: 46)
                .shadow(color: currentModeTint.opacity(0.20), radius: 16, x: 0, y: 8)

                VStack(alignment: .leading, spacing: 3) {
                    Text("会话库")
                        .font(.system(.title3, design: .rounded).weight(.black))
                    Text("\(viewModel.conversations.count) 个会话 · \(viewModel.currentMode.displayName)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer(minLength: 8)

                headerIconButton("gearshape.fill", help: "厂商配置", action: onOpenSettings)
                headerIconButton("square.and.pencil", help: "新建会话") {
                    viewModel.newConversation(mode: viewModel.activeMode)
                    onSelectConversation()
                }
            }

            HStack(spacing: 8) {
                summaryChip("\(viewModel.conversations.count)", title: "Total", icon: "tray.full.fill", color: currentModeTint)
                summaryChip(viewModel.currentMode.displayName, title: "Mode", icon: viewModel.currentMode.symbol, color: .orange)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .background {
            ZStack {
                Rectangle().fill(.thinMaterial)
                LinearGradient(
                    colors: [currentModeTint.opacity(0.14), Color.orange.opacity(0.08), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    private func headerIconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(currentModeTint)
                .frame(width: 38, height: 38)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(currentModeTint.opacity(0.18), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func summaryChip(_ value: String, title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.caption.weight(.black))
                    .lineLimit(1)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(color.opacity(0.18), lineWidth: 1)
        }
    }
    #endif

    @ViewBuilder
    private var list: some View {
        if viewModel.conversations.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 66, height: 66)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                Text("还没有会话")
                    .font(.headline.weight(.bold))
                Text("点右上 ⊕ 或直接在底部输入一条问题。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            .padding(22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .padding(16)
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(viewModel.conversations) { conv in
                        ConversationRowView(
                            conversation: conv,
                            isSelected: viewModel.selectedConversationID == conv.id,
                            isRenaming: renamingID == conv.id,
                            renameDraft: $renameDraft,
                            onSelect: {
                                viewModel.selectConversation(conv.id)
                                onSelectConversation()
                            },
                            onStartRename: {
                                renameDraft = conv.title
                                renamingID = conv.id
                            },
                            onCommitRename: {
                                let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    viewModel.renameConversation(conv.id, title: trimmed)
                                }
                                renamingID = nil
                            },
                            onCancelRename: { renamingID = nil },
                            onDelete: { viewModel.deleteConversation(conv.id) }
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                #if os(iOS)
                .padding(.bottom, 10)
                #endif
            }
        }
    }

    private var sidebarBackdrop: some View {
        ZStack {
            Color.platformWindowBackground
            LinearGradient(
                colors: [Color.accentColor.opacity(0.08), Color.clear],
                startPoint: .topLeading,
                endPoint: .center
            )
            RadialGradient(
                colors: [Color.orange.opacity(0.08), Color.clear],
                center: .bottomTrailing,
                startRadius: 40,
                endRadius: 360
            )
        }
    }

    private var currentModeTint: Color {
        switch viewModel.currentMode {
        case .council: return Color(red: 0.10, green: 0.66, blue: 0.56)
        case .direct:  return Color(red: 0.16, green: 0.48, blue: 0.94)
        case .compare: return Color(red: 0.91, green: 0.55, blue: 0.20)
        case .debate:  return Color(red: 0.88, green: 0.35, blue: 0.22)
        }
    }
}
