import SwiftUI

/// 预设「场景」:一键用某个模式 + 系统提示开聊(代码审查 / 写作 / 头脑风暴等)。
struct ScenarioTemplate: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let mode: ConversationMode
    let systemPrompt: String

    static let builtIn: [ScenarioTemplate] = [
        .init(id: "code-review", name: "代码审查", icon: "checkmark.shield.fill", mode: .direct,
              systemPrompt: "你是资深软件工程师。审查我贴出的代码:指出 bug、安全与性能风险、可读性问题,并给出改进后的完整代码与简要理由。"),
        .init(id: "writing", name: "写作润色", icon: "pencil.line", mode: .direct,
              systemPrompt: "你是专业的中文写作编辑。润色我给的文字,使其更清晰、流畅、专业,保留原意与语气;先给修改版,再用要点说明改了什么。"),
        .init(id: "brainstorm", name: "头脑风暴", icon: "lightbulb.fill", mode: .council,
              systemPrompt: "你是富有创造力的头脑风暴伙伴。围绕我的主题尽量发散出多样、具体、可执行的点子,并对每个点子用一句话点评优劣。"),
        .init(id: "tutor", name: "学习讲解", icon: "graduationcap.fill", mode: .direct,
              systemPrompt: "你是耐心的老师。用通俗的例子由浅入深讲解我问的概念,适当类比,最后出一道小练习帮我检验理解。"),
        .init(id: "decision", name: "决策分析", icon: "scalemass.fill", mode: .council,
              systemPrompt: "帮我做决策。先澄清目标与约束,列出可选方案及各自利弊与关键权衡,最后给出有明确理由的建议。"),
        .init(id: "translate", name: "翻译", icon: "character.book.closed.fill", mode: .translate,
              systemPrompt: "你是专业译者。在中英之间准确、自然地翻译我给的内容,保留语气、格式与专业术语;只输出译文,必要处可加简短注释。"),
    ]
}

struct EmptyStateCard: View {
    let mode: ConversationMode
    let providers: [ProviderConfig]
    let onOpenSettings: () -> Void
    /// 点击示例提问时回调,调用方负责新建会话并填入/发送(默认空实现,老调用方无需改动)
    var onUseSamplePrompt: (String) -> Void = { _ in }
    /// 点击场景模板时回调(默认空实现)。
    var onUseScenario: (ScenarioTemplate) -> Void = { _ in }

    private var enabledProviders: [ProviderConfig] { providers.filter(\.enabled) }
    private var modeTint: Color { mode.kownTint }

    /// 覆盖不同模式典型用法的示例提问(对比 / 头脑风暴 / 代码 / 决策等)
    private var samplePrompts: [String] {
        switch mode {
        case .council:
            return [
                "帮我头脑风暴一个面向开发者的副业产品,列 5 个方向并各给一句话理由",
                "对比 PostgreSQL、MongoDB、SQLite 在中小型项目里的取舍",
                "用 Swift 写一个带重试和超时的异步网络请求封装",
                "我想三个月内提升英语口语,请给一份可执行的周计划",
                "评审这段产品文案,指出问题并给出改写版本"
            ]
        case .direct:
            return [
                "解释一下 Swift 的 async/await 和 GCD 有什么区别",
                "帮我把这段需求拆成可执行的开发任务清单",
                "写一个 Python 脚本,批量重命名目录下的图片文件",
                "帮我润色这封求职邮件,语气专业且简洁"
            ]
        case .compare:
            return [
                "对比 SwiftUI 和 UIKit,分别适合什么场景",
                "对比 REST 和 GraphQL 的优缺点,给出选型建议",
                "对比远程办公和坐班对团队协作的影响",
                "对比三种缓存策略:本地缓存、Redis、CDN"
            ]
        case .debate:
            return [
                "辩一辩:创业初期应该先做 MVP 还是先打磨完整体验",
                "辩一辩:大型项目该用单体架构还是微服务",
                "辩一辩:团队是否值得为了类型安全全面迁移到 TypeScript",
                "辩一辩:AI 编程助手会让初级工程师更强还是更弱"
            ]
        case .structured:
            return [
                "评估 SwiftUI 作为跨平台 UI 框架的优缺点并打分",
                "从这段文字里抽取人物、地点、时间等实体",
                "把「上线一个待办 App」拆解成可执行步骤",
                "分析这条用户评论的情感倾向"
            ]
        case .tournament:
            return [
                "写一首关于秋天的现代诗,让各家比拼谁写得更好",
                "用一句话解释什么是闭包,看哪家讲得最清楚",
                "给「程序员的一天」写一个 100 字微小说,擂台决出冠军",
                "设计一个 App 启动页的文案,各家 PK 选最佳"
            ]
        case .translate:
            return [
                "把这段产品介绍翻译成地道英文",
                "Translate this paragraph into natural Simplified Chinese",
                "帮我把这封邮件翻成日语,语气礼貌得体",
                "润色这段中文,让它更流畅自然(开启润色)"
            ]
        }
    }

    @ViewBuilder
    var body: some View {
        #if os(iOS)
        mobileBody
        #else
        VStack(spacing: 22) {
            Spacer(minLength: 12)

            heroCard
                .frame(maxWidth: 760)

            scenarioCard
                .frame(maxWidth: 920)

            samplePromptCard
                .frame(maxWidth: 920)

            cardGrid
                .frame(maxWidth: 920)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    #if os(iOS)
    private var mobileBody: some View {
        VStack(spacing: 10) {
            mobileHeroCard
            scenarioCard
            samplePromptCard
            mobileQuickStartCard
            mobileProviderSummaryCard
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var mobileHeroCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [modeTint.opacity(0.20), mode.kownSecondaryTint.opacity(0.12)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image("AppIcon")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .shadow(color: modeTint.opacity(0.16), radius: 14, x: 0, y: 8)
                }
                .frame(width: 60, height: 60)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                }

                VStack(alignment: .leading, spacing: 6) {
                    modeBadge
                    Text(mode.emptyStateTitle)
                        .font(.system(size: 22, weight: .black, design: .rounded))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(mode.emptyStateSubtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Label("底部输入即可开始", systemImage: "arrow.down.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(modeTint)
                    .lineLimit(1)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(modeTint.opacity(0.12), in: Capsule())

                Spacer(minLength: 0)

                Button(action: onOpenSettings) {
                    Label(enabledProviders.isEmpty ? "启用模型" : "配置模型", systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.black))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            LinearGradient(
                                colors: [modeTint.opacity(0.98), modeTint.opacity(0.72)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground(tint: modeTint, cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(modeTint.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: modeTint.opacity(0.08), radius: 14, x: 0, y: 9)
    }

    private var mobileQuickStartCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionHeader(
                title: "快速开始",
                subtitle: "三个小动作让回答更稳定",
                icon: "sparkles",
                tint: modeTint
            )

            VStack(spacing: 8) {
                mobileTipRow("1", text: mode == .debate ? "把争议点写清楚，让模型先独立立论" : "直接描述目标、背景和你希望比较的标准")
                mobileTipRow("2", text: "需要上下文时先附图，再在问题里说明重点")
                mobileTipRow("3", text: "发送前可用「AI 改写问题」做一次整理")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground(tint: modeTint.opacity(0.88), cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private var mobileProviderSummaryCard: some View {
        let enabled = enabledProviders
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                sectionHeader(
                    title: enabled.isEmpty ? "模型未就绪" : "模型已就绪",
                    subtitle: enabled.isEmpty ? "先启用一个模型再开始" : "\(enabled.count) 个模型可参与本轮",
                    icon: enabled.isEmpty ? "exclamationmark.triangle.fill" : "checkmark.seal.fill",
                    tint: enabled.isEmpty ? .orange : modeTint
                )

                Spacer(minLength: 0)

                Button("设置", action: onOpenSettings)
                    .font(.caption.weight(.black))
                    .foregroundStyle(modeTint)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(modeTint.opacity(0.11), in: Capsule())
                    .buttonStyle(.plain)
            }

            if enabled.isEmpty {
                Text("打开设置后启用 OpenAI Compatible、Anthropic、Gemini 或 CLI Provider。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                HStack(spacing: 8) {
                    ForEach(Array(enabled.prefix(3))) { cfg in
                        mobileProviderPill(cfg)
                    }

                    if enabled.count > 3 {
                        Text("+\(enabled.count - 3)")
                            .font(.caption.weight(.black))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                            .background(Color.platformControlBackground.opacity(0.52), in: Circle())
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground(tint: .orange, cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func mobileTipRow(_ number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption.weight(.black))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(modeTint, in: Circle())
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.platformControlBackground.opacity(0.38), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func mobileProviderPill(_ cfg: ProviderConfig) -> some View {
        let tint = providerTint(cfg)
        return HStack(spacing: 7) {
            Image(systemName: providerSymbol(cfg))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            Text(cfg.displayName)
                .font(.caption.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .background(Color.platformControlBackground.opacity(0.50), in: Capsule())
    }
    #endif

    private var heroCard: some View {
        VStack(spacing: 18) {
            heroArtwork

            VStack(spacing: 10) {
                modeBadge
                Text(mode.emptyStateTitle)
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .multilineTextAlignment(.center)
                Text(mode.emptyStateSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                modeTint.opacity(0.18),
                                mode.kownSecondaryTint.opacity(mode == .debate ? 0.14 : 0.06),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(modeTint.opacity(0.20), lineWidth: 1)
        }
        .shadow(color: modeTint.opacity(0.10), radius: 28, x: 0, y: 16)
    }

    private var modeBadge: some View {
        HStack(spacing: 7) {
            Image(systemName: mode.symbol)
                .font(.caption.weight(.bold))
            Text("\(mode.localizedDisplayName)模式")
                .font(.caption.weight(.black))
                .tracking(0.7)
            Text("\(enabledProviders.count) 个已启用")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(modeTint)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(modeTint.opacity(0.12), in: Capsule())
        .overlay {
            Capsule().strokeBorder(modeTint.opacity(0.22), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var heroArtwork: some View {
        ZStack {
            Circle()
                .fill(modeTint.opacity(0.14))
                .frame(width: 180, height: 180)
                .blur(radius: 18)
                .offset(x: -26, y: 18)
            Circle()
                .fill(mode.kownSecondaryTint.opacity(0.12))
                .frame(width: 130, height: 130)
                .blur(radius: 16)
                .offset(x: 42, y: -18)

            #if os(iOS)
            Image("LaunchLogo")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 330)
                .frame(height: 230)
                .shadow(color: Color(red: 0.10, green: 0.35, blue: 0.95).opacity(0.16),
                        radius: 24, x: 0, y: 14)
            #else
            ZStack {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [modeTint.opacity(0.95), mode.kownSecondaryTint.opacity(0.78)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 112, height: 112)
            .overlay {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.32), lineWidth: 1)
            }
            .shadow(color: modeTint.opacity(0.24), radius: 24, x: 0, y: 14)
            #endif
        }
        #if os(iOS)
        .frame(height: 250)
        #else
        .frame(height: 144)
        #endif
    }

    @ViewBuilder
    private var cardGrid: some View {
        #if os(iOS)
        VStack(spacing: 14) {
            tipsCard
            councilCard
        }
        #else
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                tipsCard
                councilCard
            }
            VStack(spacing: 14) {
                tipsCard
                councilCard
            }
        }
        #endif
    }

    private var tipsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(
                title: "更稳的第一问",
                subtitle: "这些细节会明显提升整轮质量",
                icon: "sparkles",
                tint: modeTint
            )

            VStack(spacing: 10) {
                tipRow(
                    "lightbulb.fill",
                    text: mode == .debate
                        ? "有取舍、争议或策略冲突的问题,更适合用辩论模式"
                        : "把目标、背景和判断标准写清楚,多模型视角会更有价值",
                    color: .yellow
                )
                tipRow("paperclip", text: "把文件或图片拖进输入框,模型会把它们作为上下文", color: .secondary)
                tipRow("wand.and.stars", text: "发送前用「AI 改写问题」整理提示词,减少歧义", color: Color(red: 0.57, green: 0.42, blue: 0.82))
                tipRow(
                    mode == .debate ? "quote.bubble.fill" : "slider.horizontal.3",
                    text: mode == .debate
                        ? "模型会先独立立论,再阅读彼此观点并反驳收敛"
                        : "用输入栏工具切换联网、设备工具、知识库和 Persona",
                    color: .pink
                )
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(cardBackground(tint: modeTint.opacity(0.9), cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var samplePromptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: "试试这些提问",
                subtitle: "点一下填入输入框,可继续编辑后发送",
                icon: "bolt.fill",
                tint: modeTint
            )

            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(samplePrompts, id: \.self) { prompt in
                    samplePromptChip(prompt)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground(tint: modeTint.opacity(0.9), cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var scenarioCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: "场景模板",
                subtitle: "一键用预设系统提示开聊",
                icon: "square.grid.2x2.fill",
                tint: modeTint
            )
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(ScenarioTemplate.builtIn) { s in
                    Button { onUseScenario(s) } label: {
                        HStack(spacing: 7) {
                            Image(systemName: s.icon)
                                .font(.system(size: 11, weight: .black))
                                .foregroundStyle(modeTint)
                            Text(s.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(modeTint.opacity(0.10), in: Capsule())
                        .overlay { Capsule().strokeBorder(modeTint.opacity(0.20), lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                    #if os(iOS)
                    .contentShape(Capsule())
                    #endif
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground(tint: modeTint.opacity(0.9), cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func samplePromptChip(_ prompt: String) -> some View {
        Button {
            onUseSamplePrompt(prompt)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(modeTint)
                Text(prompt)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(modeTint.opacity(0.10), in: Capsule())
            .overlay {
                Capsule().strokeBorder(modeTint.opacity(0.20), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .contentShape(Capsule())
        #endif
    }

    private func sectionHeader(title: String, subtitle: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(tint.opacity(0.20), lineWidth: 1)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func tipRow(_ symbol: String, text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.platformControlBackground.opacity(0.34), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var councilCardTitle: String {
        switch mode {
        case .direct: return "对话模型"
        case .compare: return "对比模型"
        case .council: return "本轮议会阵容"
        case .debate: return "本轮辩手"
        case .structured: return "结构化模型"
        case .tournament: return "擂台参赛者"
        case .translate: return "翻译模型"
        }
    }

    private var councilCardIcon: String {
        switch mode {
        case .direct: return "bubble.left.fill"
        case .compare: return "rectangle.split.2x1.fill"
        case .council: return "person.3.fill"
        case .debate: return "quote.bubble.fill"
        case .structured: return "curlybraces"
        case .tournament: return "trophy"
        case .translate: return "globe"
        }
    }

    private var councilCard: some View {
        let enabled = enabledProviders
        let chair = enabled.first { $0.isChair }

        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                sectionHeader(
                    title: councilCardTitle,
                    subtitle: enabled.isEmpty ? "发送前请先启用至少一个模型" : "已准备好参与下一轮",
                    icon: councilCardIcon,
                    tint: modeTint
                )
                Spacer(minLength: 8)
                Button(action: onOpenSettings) {
                    Text("调整")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(modeTint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(modeTint.opacity(0.12), in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(modeTint.opacity(0.22), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
            }
            .padding(18)

            if enabled.isEmpty {
                emptyCouncilHint
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
            } else {
                VStack(spacing: 0) {
                    ForEach(enabled) { cfg in
                        councilRow(cfg: cfg, showChairBadge: false)
                        if cfg.id != enabled.last?.id {
                            Divider().opacity(0.5).padding(.leading, 58).padding(.trailing, 18)
                        }
                    }
                    if let chair {
                        Divider().opacity(0.5).padding(.horizontal, 18).padding(.top, 8)
                        councilRow(cfg: chair, showChairBadge: true)
                            .padding(.top, 4)
                    }
                }
                .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(cardBackground(tint: modeTint, cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var emptyCouncilHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 42, height: 42)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text("还没启用任何模型")
                .font(.callout.weight(.semibold))
            Text("点「调整」在配置里启用至少一个 Provider。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.16), lineWidth: 1)
        }
    }

    private func councilRow(cfg: ProviderConfig, showChairBadge: Bool) -> some View {
        let tint = showChairBadge ? Color.orange : providerTint(cfg)
        return HStack(spacing: 12) {
            Image(systemName: showChairBadge ? "crown.fill" : providerSymbol(cfg))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(tint.opacity(0.18), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(cfg.displayName)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if showChairBadge {
                        Text(mode == .debate ? "主持" : "主席")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.14), in: Capsule())
                            .foregroundStyle(Color.orange)
                    }
                }
                Text(cfg.model)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(cfg.kind.compactName)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(tint.opacity(0.10), in: Capsule())
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func cardBackground(tint: Color, cornerRadius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.08), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }

    private func providerTint(_ cfg: ProviderConfig) -> Color {
        cfg.kownTint
    }

    private func providerSymbol(_ cfg: ProviderConfig) -> String {
        cfg.kownSymbol
    }
}

private extension ProviderKind {
    var compactName: String {
        switch self {
        case .openAICompatible: return "openai"
        case .anthropic:        return "anthropic"
        case .gemini:           return "google"
        case .cliCommand:       return "cli"
        case .appleFM:          return "apple"
        }
    }
}

/// 自动换行的流式布局,用于示例提问胶囊(macOS 13 / iOS 16 起可用)
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + lineSpacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)

        let resolvedWidth = proposal.width ?? totalWidth
        return CGSize(width: resolvedWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
