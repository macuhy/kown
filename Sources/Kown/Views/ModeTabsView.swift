import SwiftUI

struct ModeTabsView: View {
    @Bindable var viewModel: AppViewModel
    @State private var pendingMode: ConversationMode?
    @State private var confirmSwitch = false

    var body: some View {
        let tint = viewModel.currentMode.kownTint
        ViewThatFits(in: .horizontal) {
            tabs(showLabels: true)
            tabs(showLabels: false)
        }
        .padding(4)
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
                            colors: [tint.opacity(0.12), viewModel.currentMode.kownSecondaryTint.opacity(0.05), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .overlay {
            Capsule().strokeBorder(tint.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: tint.opacity(0.10), radius: 18, x: 0, y: 9)
        .animation(.spring(response: 0.26, dampingFraction: 0.82), value: viewModel.currentMode)
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
            Text("当前会话已有问答记录，切到 \(pendingMode?.localizedDisplayName ?? "") 模式会新建一个会话。")
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
        let tint = mode.kownTint
        return Button {
            handleTap(mode)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.symbol)
                    .font(.system(size: tabIconSize, weight: .bold))
                if showLabel {
                    Text(mode.localizedDisplayName)
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
                                colors: [tint.opacity(0.98), mode.kownSecondaryTint.opacity(0.78)],
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
        .help(mode.localizedDisplayName)
        .accessibilityLabel(mode.localizedDisplayName)
        .accessibilityValue(isActive ? "当前模式" : "未选中")
        .accessibilityHint(isActive ? "已选择" : "切换到此模式")
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
        showLabel ? 5 : 9
        #else
        showLabel ? 11 : 10
        #endif
    }

    private var tabVerticalPadding: CGFloat {
        #if os(iOS)
        6
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

}
