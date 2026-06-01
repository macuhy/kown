import SwiftUI

struct ModeTabsView: View {
    @Bindable var viewModel: AppViewModel
    @State private var pendingMode: ConversationMode?
    @State private var confirmSwitch = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            tabs(showLabels: true)
            tabs(showLabels: false)
        }
        .padding(3)
        #if os(iOS)
        .frame(maxWidth: .infinity)
        #endif
        .background {
            ZStack {
                Capsule()
                    .fill(.regularMaterial)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [modeTint(viewModel.currentMode).opacity(0.10), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .overlay {
            Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: modeTint(viewModel.currentMode).opacity(0.08), radius: 16, x: 0, y: 8)
        .animation(.easeInOut(duration: 0.16), value: viewModel.currentMode)
        .confirmationDialog(
            "切换模式将开始一个新会话",
            isPresented: $confirmSwitch
        ) {
            Button("继续") {
                if let m = pendingMode { viewModel.newConversation(mode: m) }
                pendingMode = nil
            }
            Button("取消", role: .cancel) { pendingMode = nil }
        } message: {
            Text("当前会话已有问答记录，切到 \(pendingMode?.displayName ?? "") 模式会新建一个会话。")
        }
    }

    private func tabs(showLabels: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(ConversationMode.allCases, id: \.self) { mode in
                tab(for: mode, showLabel: showLabels)
            }
        }
    }

    private func tab(for mode: ConversationMode, showLabel: Bool) -> some View {
        let isActive = viewModel.currentMode == mode
        let tint = modeTint(mode)
        return Button {
            handleTap(mode)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.symbol)
                    .font(.system(size: tabIconSize, weight: .bold))
                if showLabel {
                    Text(mode.displayName)
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                }
            }
            .font(tabFont)
            .foregroundStyle(isActive ? Color.white : Color.secondary)
            .padding(.horizontal, tabHorizontalPadding(showLabel: showLabel))
            .padding(.vertical, tabVerticalPadding)
            #if os(iOS)
            .frame(maxWidth: .infinity, minHeight: 32)
            #endif
            .background {
                if isActive {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.98), tint.opacity(0.72)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                } else {
                    Capsule().fill(Color.clear)
                }
            }
            .overlay {
                Capsule()
                    .strokeBorder(isActive ? Color.white.opacity(0.24) : Color.clear, lineWidth: 1)
            }
            .shadow(color: isActive ? tint.opacity(0.18) : Color.clear, radius: 10, x: 0, y: 5)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(mode.displayName)
        .accessibilityLabel(mode.displayName)
    }

    private var tabFont: Font {
        #if os(iOS)
        .caption2.weight(.black)
        #else
        .caption.weight(.bold)
        #endif
    }

    private var tabIconSize: CGFloat {
        #if os(iOS)
        12
        #else
        12
        #endif
    }

    private func tabHorizontalPadding(showLabel: Bool) -> CGFloat {
        #if os(iOS)
        showLabel ? 3 : 8
        #else
        showLabel ? 11 : 10
        #endif
    }

    private var tabVerticalPadding: CGFloat {
        #if os(iOS)
        5
        #else
        6
        #endif
    }

    private func handleTap(_ mode: ConversationMode) {
        guard viewModel.currentMode != mode else { return }
        if let id = viewModel.selectedConversationID,
           let conv = viewModel.conversations.first(where: { $0.id == id }),
           !conv.turns.isEmpty {
            pendingMode = mode
            confirmSwitch = true
        } else {
            _ = viewModel.switchMode(to: mode)
        }
    }

    private func modeTint(_ mode: ConversationMode) -> Color {
        switch mode {
        case .council: return Color(red: 0.10, green: 0.66, blue: 0.56)
        case .direct:  return Color(red: 0.16, green: 0.48, blue: 0.94)
        case .compare: return Color(red: 0.91, green: 0.55, blue: 0.20)
        case .debate:  return Color(red: 0.88, green: 0.35, blue: 0.22)
        }
    }
}
