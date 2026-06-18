import SwiftUI

/// 可折叠的「💭 思考过程」区块。供 live 回答卡(ResponseColumnView)、历史卡
/// (HistoricalResponseCard)、Chair/Summary 卡复用。
/// - streaming 期间默认展开(便于看推理实时流出),生成结束自动收起。
/// - 思考文本一般是较长的纯文本,这里用轻量的滚动 Text 渲染(不走 cmark),避免拖慢。
struct ReasoningDisclosure: View {
    let reasoning: String
    var streaming: Bool = false
    var tint: Color = .purple

    @State private var expanded = false

    /// 流式时只渲染最新一段思考文本。完整 reasoning 仍保存在 ResponseState 里,结束后可展开查看。
    /// 这样扩展思考模型输出几十 KB 时,不会每次 UI flush 都让单个 Text 重测全文。
    private static let liveVisibleReasoningChars = 8_000

    /// 渲染用文本:实时流式已在 ResponseState.flushPending 封顶,但更早落盘的历史 reasoning 可能超长。
    /// 再兜一层,避免单个 Text(reasoning) 整段测量烧 CPU(与 ResponseState.maxReasoningChars 对齐)。
    private var displayReasoning: String {
        if streaming, Self.isLonger(reasoning, than: Self.liveVisibleReasoningChars) {
            return "…\n" + String(reasoning.suffix(Self.liveVisibleReasoningChars))
        }
        if Self.isLonger(reasoning, than: ResponseState.maxReasoningChars) {
            return String(reasoning.prefix(ResponseState.maxReasoningChars)) + "…"
        }
        return reasoning
    }

    private var countLabel: String {
        let count = reasoning.utf16.count
        return count >= 10_000 ? "\(count / 1000)k 字" : "\(count) 字"
    }

    var body: some View {
        if !reasoning.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "brain")
                            .font(.caption.weight(.bold))
                        Text("思考过程")
                            .font(.caption.weight(.bold))
                        if streaming {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text(countLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(tint.opacity(0.20), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)

                if expanded {
                    ScrollView {
                        Text(displayReasoning)
                            .font(.system(.caption, design: .default))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(maxHeight: 260)
                    .background(tint.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { expanded = streaming }
            .onChange(of: streaming) { _, nowStreaming in
                if !nowStreaming { withAnimation(.easeInOut(duration: 0.18)) { expanded = false } }
            }
        }
    }

    private static func isLonger(_ text: String, than limit: Int) -> Bool {
        guard let idx = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex) else {
            return false
        }
        return idx < text.endIndex
    }
}

/// 单轮成本 / token 角标。查得到单价显示「$0.0012 · 1.2k tok」,查不到只显示 token 数。
struct TokenCostPill: View {
    let usage: TurnTokenUsage
    let model: String
    let providerKind: ProviderKind

    var body: some View {
        let total = usage.input + usage.output
        let cost = ProviderModelCatalog.estimatedCost(
            model: model, providerKind: providerKind,
            input: usage.input, output: usage.output
        )
        Label(label(total: total, cost: cost), systemImage: "dollarsign.circle")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.08), in: Capsule())
            .help(helpText(cost: cost))
    }

    private func label(total: Int, cost: Double?) -> String {
        var s = Self.formatTokens(total)
        if let cost { s = "\(Self.formatCost(cost)) · \(s)" }
        if usage.cachedInput > 0 {
            let pct = usage.input > 0 ? Int((Double(usage.cachedInput) * 100 / Double(usage.input)).rounded()) : 0
            let n = usage.cachedInput >= 1000 ? String(format: "%.1fk", Double(usage.cachedInput) / 1000) : "\(usage.cachedInput)"
            s += " · 缓存 \(n)(\(pct)%)"
        }
        return s
    }

    private func helpText(cost: Double?) -> String {
        var t = "输入 \(usage.input) · 输出 \(usage.output) token"
        if usage.cachedInput > 0 { t += " · 命中缓存 \(usage.cachedInput)(输入里已含)" }
        t += cost != nil ? "(估算成本,实际以账单为准)" : "(该模型无内置单价)"
        return t
    }

    static func formatTokens(_ n: Int) -> String {
        if n >= 1000 {
            return String(format: "%.1fk tok", Double(n) / 1000)
        }
        return "\(n) tok"
    }

    static func formatCost(_ usd: Double) -> String {
        if usd >= 0.01 {
            return String(format: "$%.2f", usd)
        } else if usd > 0 {
            return String(format: "$%.4f", usd)
        }
        return "$0"
    }
}
