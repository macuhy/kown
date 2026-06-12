import SwiftUI

enum KownTheme {
    enum Radius {
        static let sm: CGFloat = 10
        static let md: CGFloat = 14
        static let lg: CGFloat = 18
        static let xl: CGFloat = 24
    }

    enum Spacing {
        static let xs: CGFloat = 6
        static let sm: CGFloat = 10
        static let md: CGFloat = 14
        static let lg: CGFloat = 18
        static let xl: CGFloat = 24
    }

    static var hairline: Color {
        Color.primary.opacity(0.08)
    }

    static var quietStroke: Color {
        Color.primary.opacity(0.07)
    }

    static var quietFill: Color {
        Color.platformControlBackground.opacity(0.42)
    }

    static func shadow(_ tint: Color, active: Bool = false) -> Color {
        tint.opacity(active ? 0.18 : 0.07)
    }
}

extension ConversationMode {
    var kownTint: Color {
        switch self {
        case .council: return Color(red: 0.10, green: 0.66, blue: 0.56)
        case .direct:  return Color(red: 0.16, green: 0.48, blue: 0.94)
        case .compare: return Color(red: 0.91, green: 0.55, blue: 0.20)
        case .debate:  return Color(red: 0.88, green: 0.35, blue: 0.22)
        case .structured: return Color(red: 0.36, green: 0.42, blue: 0.92)
        case .tournament: return Color(red: 0.85, green: 0.62, blue: 0.13)
        case .translate: return Color(red: 0.49, green: 0.34, blue: 0.78)
        }
    }

    var kownSecondaryTint: Color {
        switch self {
        case .council: return Color(red: 0.18, green: 0.78, blue: 0.68)
        case .direct:  return Color(red: 0.24, green: 0.68, blue: 1.00)
        case .compare: return Color(red: 0.98, green: 0.70, blue: 0.26)
        case .debate:  return Color(red: 0.98, green: 0.46, blue: 0.28)
        case .structured: return Color(red: 0.50, green: 0.60, blue: 1.00)
        case .tournament: return Color(red: 0.96, green: 0.74, blue: 0.22)
        case .translate: return Color(red: 0.64, green: 0.50, blue: 0.92)
        }
    }

    var kownModeDescription: String {
        switch self {
        case .council: return "多模型参议，主席收敛结论"
        case .direct:  return "单模型快速对话"
        case .compare: return "双模型并排对照"
        case .debate:  return "多轮辩论后给结论"
        case .structured: return "按 JSON Schema 输出并校验"
        case .tournament: return "模型擂台逐轮决出冠军"
        case .translate: return "翻译 / 润色改写"
        }
    }

    var kownPromptPlaceholder: String {
        switch self {
        case .council: return "Ask the council..."
        case .direct:  return "Send a message..."
        case .compare: return "Ask both models..."
        case .debate:  return "Start a debate..."
        case .structured: return "Ask for structured JSON..."
        case .tournament: return "Start a tournament..."
        case .translate: return "粘贴要翻译 / 改写的文本..."
        }
    }
}

extension ProviderKind {
    var kownTint: Color {
        switch self {
        case .openAICompatible: return Color(red: 0.06, green: 0.64, blue: 0.50)
        case .anthropic:        return Color(red: 0.83, green: 0.38, blue: 0.18)
        case .gemini:           return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .cliCommand:       return Color(red: 0.55, green: 0.45, blue: 0.78)
        case .appleFM:          return Color(red: 0.78, green: 0.40, blue: 0.86)
        }
    }

    var kownSymbol: String {
        switch self {
        case .openAICompatible: return "sparkles"
        case .anthropic:        return "text.book.closed"
        case .gemini:           return "diamond.fill"
        case .cliCommand:       return "terminal"
        case .appleFM:          return "apple.logo"
        }
    }
}

extension ProviderConfig {
    var kownTint: Color { kind.kownTint }
    var kownSymbol: String { kind.kownSymbol }
}

struct KownGlassCard<Content: View>: View {
    let tint: Color
    var cornerRadius: CGFloat = KownTheme.Radius.lg
    var intensity: Double = 0.08
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.regularMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(intensity), Color.platformControlBackground.opacity(0.20), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(tint.opacity(0.16), lineWidth: 1)
            }
            .shadow(color: KownTheme.shadow(tint), radius: 18, x: 0, y: 10)
    }
}

struct KownModeMark: View {
    let mode: ConversationMode
    var size: CGFloat = 38
    var selected: Bool = true

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            mode.kownTint.opacity(selected ? 0.96 : 0.18),
                            mode.kownSecondaryTint.opacity(selected ? 0.72 : 0.09)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: mode.symbol)
                .font(.system(size: max(12, size * 0.40), weight: .bold))
                .foregroundStyle(selected ? Color.white : mode.kownTint)
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                .strokeBorder((selected ? Color.white : mode.kownTint).opacity(selected ? 0.28 : 0.18), lineWidth: 1)
        }
        .shadow(color: mode.kownTint.opacity(selected ? 0.16 : 0.04), radius: selected ? 12 : 6, x: 0, y: selected ? 6 : 3)
    }
}
