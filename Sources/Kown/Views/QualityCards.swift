import SwiftUI

/// 自我反思修订结果卡:展示「批评」+「修订答案」。视觉对齐 `SourcesStrip`(material + 渐变描边)。
struct SelfRevisionCard: View {
    let revision: SelfRevision
    /// providerID(uuidString) → 展示名。
    let providerName: String?
    @State private var showCritique = false

    private var tint: Color { Color(red: 0.55, green: 0.36, blue: 0.86) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.bold)).foregroundStyle(tint)
                Text("自我反思修订").font(.caption.weight(.bold)).foregroundStyle(tint)
                Spacer()
                if let name = providerName {
                    Text(name).font(.caption2.weight(.bold)).foregroundStyle(tint)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(tint.opacity(0.11), in: Capsule())
                }
            }

            if !revision.critique.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showCritique.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showCritique ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.bold))
                        Text("查看批评意见").font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showCritique {
                    MarkdownText(text: revision.critique)
                        .font(.callout)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            Text("修订后的答案").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            MarkdownText(text: revision.revised)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground(tint))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.24), lineWidth: 1)
        }
    }
}

/// 事实核查结果卡:逐条论断 + 判定徽章(已验证 / 存疑 / 无法核实)+ 来源。
struct FactCheckCard: View {
    let result: FactCheckResult
    let providerName: String?

    private var tint: Color { Color(red: 0.20, green: 0.62, blue: 0.45) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield")
                    .font(.caption.weight(.bold)).foregroundStyle(tint)
                Text("事实核查(\(result.claims.count))").font(.caption.weight(.bold)).foregroundStyle(tint)
                Spacer()
                if let name = providerName {
                    Text(name).font(.caption2.weight(.bold)).foregroundStyle(tint)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(tint.opacity(0.11), in: Capsule())
                }
            }
            ForEach(result.claims) { claim in
                claimRow(claim)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground(tint))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.24), lineWidth: 1)
        }
    }

    private func claimRow(_ claim: FactCheckResult.Claim) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                verdictBadge(claim.verdict)
                Text(claim.claim)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !claim.note.isEmpty {
                Text(claim.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !claim.sources.isEmpty {
                SourcesChip(sources: claim.sources)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func verdictBadge(_ verdict: String) -> some View {
        let (label, color, icon): (String, Color, String) = {
            switch verdict {
            case "verified":  return ("已验证", Color(red: 0.18, green: 0.65, blue: 0.40), "checkmark.seal.fill")
            case "doubtful":  return ("存疑", Color(red: 0.86, green: 0.45, blue: 0.16), "exclamationmark.triangle.fill")
            default:           return ("无法核实", .secondary, "questionmark.circle.fill")
            }
        }()
        return Label(label, systemImage: icon)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .fixedSize()
    }
}

/// 可信度 / 证据锁定卡:本地列出关键事实句是否绑定来源。
struct AnswerTrustCard: View {
    let report: AnswerTrustReport

    private var tint: Color {
        switch report.verdict {
        case "high": return Color(red: 0.18, green: 0.62, blue: 0.42)
        case "medium": return Color(red: 0.88, green: 0.52, blue: 0.18)
        default: return Color(red: 0.82, green: 0.30, blue: 0.26)
        }
    }

    private var scoreLabel: String {
        switch report.verdict {
        case "high": return "可信度高"
        case "medium": return "中等可信"
        default: return "需要补证据"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                Text("可信度 / 证据锁定")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                Spacer()
                Text("\(report.score)")
                    .font(.caption.weight(.black))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(tint.opacity(0.12), in: Capsule())
            }
            Text("\(scoreLabel) · \(report.summary)")
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                metaChip("Web \(report.sourceCount)", icon: "globe")
                metaChip("知识库 \(report.knowledgeSourceCount)", icon: "books.vertical")
                metaChip(report.evidenceLocked ? "证据锁定" : "普通分析", icon: "lock.shield")
            }

            if report.claims.isEmpty {
                Text("没有发现明显需要逐句补证据的事实性强论断。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(report.claims) { claim in
                        claimRow(claim)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground(tint))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.24), lineWidth: 1)
        }
    }

    private func claimRow(_ claim: AnswerTrustReport.Claim) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                claimBadge(claim.verdict)
                Text(claim.text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(claim.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func claimBadge(_ verdict: String) -> some View {
        let (label, color, icon): (String, Color, String) = {
            switch verdict {
            case "supported": return ("有证据", Color(red: 0.18, green: 0.62, blue: 0.42), "link.badge.plus")
            case "weak": return ("弱证据", Color(red: 0.88, green: 0.52, blue: 0.18), "exclamationmark.triangle")
            default: return ("缺证据", Color(red: 0.82, green: 0.30, blue: 0.26), "lock.slash")
            }
        }()
        return Label(label, systemImage: icon)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .fixedSize()
    }

    private func metaChip(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.09), in: Capsule())
            .fixedSize()
    }
}

/// 合成最优终稿结果卡:展示「最优答案」+ 可展开的「合成说明」。视觉对齐 `SelfRevisionCard`。
struct SynthesisCard: View {
    let conclusion: SynthesizedConclusion
    /// 执行合成的 provider 展示名。
    let providerName: String?
    @State private var showRationale = false

    private var tint: Color { Color(red: 0.20, green: 0.62, blue: 0.52) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.caption.weight(.bold)).foregroundStyle(tint)
                Text("合成最优答案").font(.caption.weight(.bold)).foregroundStyle(tint)
                Spacer()
                if let name = providerName {
                    Text(name).font(.caption2.weight(.bold)).foregroundStyle(tint)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(tint.opacity(0.11), in: Capsule())
                }
            }

            if !conclusion.rationale.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showRationale.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showRationale ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.bold))
                        Text("查看合成说明").font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showRationale {
                    MarkdownText(text: conclusion.rationale)
                        .font(.callout)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            MarkdownText(text: conclusion.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground(tint))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.24), lineWidth: 1)
        }
    }
}

/// 合成区:opt-in「合成最优答案」按钮 + 结果卡。Council / Compare 共用。
struct SynthesisSection: View {
    let conclusion: SynthesizedConclusion?
    let providerName: String?
    let isSynthesizing: Bool
    let error: String?
    let onSynthesize: () -> Void

    private var tint: Color { Color(red: 0.20, green: 0.62, blue: 0.52) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let conclusion {
                SynthesisCard(conclusion: conclusion, providerName: providerName)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: onSynthesize) {
                HStack(spacing: 6) {
                    if isSynthesizing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "wand.and.stars")
                    }
                    Text(isSynthesizing ? "合成中…" : (conclusion == nil ? "合成最优答案" : "重新合成"))
                        .font(.callout.weight(.medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(tint.opacity(0.12), in: Capsule())
                .foregroundStyle(tint)
            }
            .buttonStyle(.plain)
            .disabled(isSynthesizing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 红队压测结果卡:逐条「攻击 → 辩护/改口」+ 类型徽章 + 红队整体结论。视觉对齐 `FactCheckCard`(红色调=对抗)。
struct RedTeamCard: View {
    let result: RedTeamResult
    /// 红队(对手模型)展示名。
    let redName: String?
    /// 辩护方展示名。
    let defenderName: String?

    private var tint: Color { Color(red: 0.82, green: 0.30, blue: 0.26) }

    /// 改口(承认问题)的攻击数 —— 头部摘要用。
    private var concededCount: Int {
        result.attacks.filter { $0.resolution == "conceded" }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                    .font(.caption.weight(.bold)).foregroundStyle(tint)
                Text("红队压测(\(result.attacks.count))").font(.caption.weight(.bold)).foregroundStyle(tint)
                if concededCount > 0 {
                    Text("\(concededCount) 处改口")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color(red: 0.86, green: 0.45, blue: 0.16))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color(red: 0.86, green: 0.45, blue: 0.16).opacity(0.14), in: Capsule())
                }
                Spacer()
                if let red = redName {
                    Label(red, systemImage: "burst.fill")
                        .font(.caption2.weight(.bold)).foregroundStyle(tint)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(tint.opacity(0.11), in: Capsule())
                }
            }

            if !result.verdict.isEmpty {
                Text(result.verdict)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(result.attacks) { attack in
                attackRow(attack)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground(tint))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.24), lineWidth: 1)
        }
    }

    private func attackRow(_ attack: RedTeamResult.Attack) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                kindBadge(attack.kind)
                if !attack.claim.isEmpty {
                    Text(attack.claim)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            if !attack.attack.isEmpty {
                Label(attack.attack, systemImage: "exclamationmark.bubble")
                    .font(.caption)
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !attack.defense.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    resolutionBadge(attack.resolution)
                    Text(attack.defense)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func kindBadge(_ kind: String) -> some View {
        let (color, icon): (Color, String) = {
            switch kind {
            case "hallucination": return (Color(red: 0.82, green: 0.30, blue: 0.26), "wand.and.stars.inverse")
            case "unsourced":     return (Color(red: 0.55, green: 0.36, blue: 0.86), "link.badge.plus")
            default:               return (Color(red: 0.86, green: 0.55, blue: 0.16), "questionmark.diamond.fill")
            }
        }()
        return Label(RedTeamService.kindLabel(kind), systemImage: icon)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .fixedSize()
    }

    private func resolutionBadge(_ resolution: String) -> some View {
        let (label, color, icon): (String, Color, String) = {
            if resolution == "conceded" {
                return ("改口", Color(red: 0.86, green: 0.45, blue: 0.16), "arrow.uturn.left")
            }
            return ("辩护", Color(red: 0.18, green: 0.60, blue: 0.42), "checkmark.shield.fill")
        }()
        return Label(label, systemImage: icon)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .fixedSize()
    }
}

/// 两张卡共用的 material + 渐变背景。
private func cardBackground(_ tint: Color) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial)
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.10), .clear],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}
