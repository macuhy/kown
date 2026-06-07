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

/// 两张卡共用的 material + 渐变背景。
private func cardBackground(_ tint: Color) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial)
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.10), .clear],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}
