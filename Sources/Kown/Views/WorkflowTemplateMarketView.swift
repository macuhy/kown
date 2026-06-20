import SwiftUI

/// 设置 ▸ 流程模板:把常见多步 AI 工作流一键安装成 Prompt Chain。
struct WorkflowTemplateMarketView: View {
    @State private var installedChains: [PromptChain] = []
    @State private var installMessage: String?

    private let templates = WorkflowTemplate.builtIns
    private let tint = Color(red: 0.36, green: 0.50, blue: 0.88)

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                header
                if let installMessage {
                    Label(installMessage, systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14, alignment: .top)], spacing: 14) {
                    ForEach(templates) { template in
                        templateCard(template)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear(perform: reload)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up.badge.plus")
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("工作流模板")
                        .font(.title2.weight(.black))
                    Text("把高频任务安装成 Prompt Chain,之后可继续编辑每一步模型与指令。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(templates.count) 个模板")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(tint.opacity(0.12), in: Capsule())
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func templateCard(_ template: WorkflowTemplate) -> some View {
        let installed = isInstalled(template)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: template.icon)
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(template.tint)
                    .frame(width: 38, height: 38)
                    .background(template.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(template.title)
                        .font(.headline.weight(.bold))
                    Text(template.category)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(template.tint)
                }
                Spacer(minLength: 0)
                if installed {
                    Label("已安装", systemImage: "checkmark.circle.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.green)
                }
            }

            Text(template.description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(template.chain.steps.enumerated()), id: \.element.id) { index, step in
                    HStack(spacing: 7) {
                        Text("\(index + 1)")
                            .font(.caption2.weight(.black))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(template.tint, in: Circle())
                        Text(step.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 0)

            Button {
                install(template)
            } label: {
                Label(installed ? "再安装一份" : "安装到工作流", systemImage: installed ? "plus.square.on.square" : "square.and.arrow.down")
                    .font(.caption.weight(.bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(template.tint)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 270, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func reload() {
        installedChains = PromptChainStore.load()
    }

    private func isInstalled(_ template: WorkflowTemplate) -> Bool {
        installedChains.contains { $0.name == template.chain.name }
    }

    private func install(_ template: WorkflowTemplate) {
        var chain = template.chain
        if isInstalled(template) {
            chain.name = "\(chain.name) 副本"
        }
        installedChains.insert(chain, at: 0)
        PromptChainStore.save(installedChains)
        installMessage = "已安装「\(chain.name)」,可到「工作流」继续编辑和运行。"
    }
}
private struct WorkflowTemplate: Identifiable {
    let id: String
    let title: String
    let category: String
    let description: String
    let icon: String
    let tint: Color
    let chain: PromptChain
}

private extension WorkflowTemplate {
    static let builtIns: [WorkflowTemplate] = [
        WorkflowTemplate(
            id: "research-deliverable",
            title: "调研到交付",
            category: "研究 / 汇报",
            description: "从问题拆解、资料提炼、报告起草到交付检查,适合竞品调研、技术趋势和奖项材料。",
            icon: "doc.text.magnifyingglass",
            tint: Color(red: 0.16, green: 0.48, blue: 0.88),
            chain: PromptChain(name: "调研到交付", steps: [
                ChainStep(title: "研究拆解", instruction: """
                请把下面的研究目标拆成可执行的调研大纲。
                输出:关键问题、需要验证的假设、建议搜索关键词、最终交付结构。

                研究目标:
                {{input}}
                """),
                ChainStep(title: "资料提炼", instruction: """
                你是研究分析师。基于上一步大纲,整理一份资料提炼框架。
                要求:区分事实、判断和待验证缺口;列出需要引用来源的点。

                上一步:
                {{prev}}
                """),
                ChainStep(title: "报告草稿", instruction: """
                请把研究结果写成可交付报告草稿。
                结构:摘要、背景、关键发现、证据、风险/缺口、建议下一步。

                原始目标:
                {{input}}

                研究框架:
                {{prev}}
                """),
                ChainStep(title: "交付检查", instruction: """
                请审查下面报告是否适合交付。
                输出:缺少的证据、表达风险、可删减内容、最终修改建议。

                报告草稿:
                {{prev}}
                """)
            ])
        ),
        WorkflowTemplate(
            id: "meeting-loop",
            title: "会议闭环",
            category: "会议 / 跟进",
            description: "把零散会议记录转成决策、风险、行动项和跟进邮件,适合例会、评审和需求讨论。",
            icon: "person.2.wave.2",
            tint: Color(red: 0.86, green: 0.44, blue: 0.18),
            chain: PromptChain(name: "会议闭环", steps: [
                ChainStep(title: "纪要整理", instruction: """
                请把下面的会议记录整理成结构化纪要。
                输出:会议摘要、讨论要点、明确决策、未决问题。

                会议记录:
                {{input}}
                """),
                ChainStep(title: "行动项提炼", instruction: """
                请从纪要中提炼行动项表格。
                列:任务、负责人、截止日期、依赖、风险。缺失信息用「待确认」。

                纪要:
                {{prev}}
                """),
                ChainStep(title: "跟进草稿", instruction: """
                请写一封会后跟进消息,语气简洁明确。
                包含:感谢、决策摘要、行动项、下次检查点。

                行动项:
                {{prev}}
                """)
            ])
        ),
        WorkflowTemplate(
            id: "red-team-review",
            title: "红队审稿",
            category: "质量 / 风险",
            description: "先起草,再专门挑错,最后重写定稿。适合重要文案、方案和对外材料。",
            icon: "shield.lefthalf.filled",
            tint: Color(red: 0.82, green: 0.24, blue: 0.28),
            chain: PromptChain(name: "红队审稿", steps: [
                ChainStep(title: "初稿", instruction: "请根据下面需求写一版清晰、完整的初稿:\n\n{{input}}"),
                ChainStep(title: "红队", instruction: """
                你是严格红队审稿人。请专挑下面初稿的问题:
                1. 事实或逻辑漏洞
                2. 证据不足
                3. 容易被误解的表达
                4. 可以删减的废话

                初稿:
                {{prev}}
                """),
                ChainStep(title: "定稿", instruction: """
                请结合红队意见重写最终稿。只输出最终稿,不要复述修改说明。

                原始需求:
                {{input}}

                红队意见:
                {{prev}}
                """)
            ])
        ),
        WorkflowTemplate(
            id: "competitor-compare",
            title: "竞品对比",
            category: "产品 / 决策",
            description: "先定义对比维度,再做评分矩阵,最后输出产品策略建议。",
            icon: "scale.3d",
            tint: Color(red: 0.22, green: 0.58, blue: 0.52),
            chain: PromptChain(name: "竞品对比", steps: [
                ChainStep(title: "维度设计", instruction: """
                请为下面的竞品分析设计评估维度。
                输出:用户场景、功能、体验、价格、渠道、风险、可验证指标。

                分析对象:
                {{input}}
                """),
                ChainStep(title: "对比矩阵", instruction: """
                请基于这些维度生成对比矩阵模板,并说明每个维度如何打分。

                维度:
                {{prev}}
                """),
                ChainStep(title: "策略建议", instruction: """
                请根据对比矩阵给出产品策略建议。
                输出:可学什么、避开什么、短期机会、长期壁垒。

                原始对象:
                {{input}}

                矩阵:
                {{prev}}
                """)
            ])
        ),
        WorkflowTemplate(
            id: "code-review",
            title: "代码审查流水线",
            category: "开发 / 审查",
            description: "按正确性、边界、测试和可维护性审查代码或 PR 描述,最后生成修改清单。",
            icon: "chevron.left.forwardslash.chevron.right",
            tint: Color(red: 0.42, green: 0.46, blue: 0.78),
            chain: PromptChain(name: "代码审查流水线", steps: [
                ChainStep(title: "行为理解", instruction: """
                请阅读下面的代码或 PR 描述,先概括它想改变什么行为。
                不要急着给建议,先确认影响面。

                {{input}}
                """),
                ChainStep(title: "风险审查", instruction: """
                请从 bug、边界条件、并发/状态、数据迁移、用户体验和测试缺口角度审查。
                按严重程度排序。

                行为理解:
                {{prev}}
                """),
                ChainStep(title: "修改清单", instruction: """
                请把审查结果整理成可执行修改清单。
                每条包含:问题、建议改法、建议测试。

                审查结果:
                {{prev}}
                """)
            ])
        )
    ]
}
