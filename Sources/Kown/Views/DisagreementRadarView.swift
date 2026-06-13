import SwiftUI

/// 分歧雷达:把 `ConsensusAnalysis` 的逐家立场做成一个**只看分歧**的醒目视图 ——
/// 多模型回答后,「哪几家一个立场、哪几家另一个立场,各自理由」一屏直给,共识默认折叠收进底部。
///
/// 复用 `ConsensusAnalyzer` 现成输出(`disagreementPoints`,每点带 `positions[{model, stance}]`),
/// **不重算**;只在视图层把重心从「共识+分歧并列」反转成「分歧优先、共识次要」。
/// 仅当分析含结构化分歧点(`disagreementPoints`)时才有意义;没有结构化分歧点时调用方不应展示本视图。
struct DisagreementRadarView: View {
    let analysis: ConsensusAnalysis

    @State private var showAgreements = false

    private var tint: Color { Color(red: 0.86, green: 0.42, blue: 0.18) }
    private var agreeColor: Color { Color(red: 0.16, green: 0.62, blue: 0.40) }

    /// 结构化分歧点(本视图的核心);空数组时整体不渲染主体。
    private var points: [ConsensusDisagreement] {
        analysis.disagreementPoints ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if points.isEmpty {
                // 没有结构化分歧点(可能各家高度一致)。给一句轻提示,而不是空卡。
                Label("各模型在主要结论上未现明显分歧。", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(agreeColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(points.enumerated()), id: \.offset) { idx, point in
                    pointCard(index: idx + 1, point: point)
                }
            }

            // 共识折叠在底部 —— 想看一致点能展开,但不抢分歧的视觉重心。
            if !analysis.agreements.isEmpty {
                agreementsDisclosure
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.12), .clear],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(tint.opacity(0.30), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.9), tint.opacity(0.5)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.white).font(.system(size: 13, weight: .bold))
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("分歧雷达")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(.primary)
                if !points.isEmpty {
                    Text("\(points.count) 个分歧点 · 各家立场对照")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let score = analysis.agreementScore {
                Text("\(score)% 一致")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(scoreColor(score))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(scoreColor(score).opacity(0.14), in: Capsule())
            }
        }
    }

    /// 单个分歧点卡:点题 + 「N 家表态」摘要 + 各家立场逐行(模型徽章 + 立场)。
    private func pointCard(index: Int, point: ConsensusDisagreement) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(index)")
                    .font(.caption.weight(.heavy)).monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(tint, in: Circle())
                Text(point.point)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            if !point.positions.isEmpty {
                Text(positionsSummary(point.positions))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)

                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(point.positions.enumerated()), id: \.offset) { _, pos in
                        positionRow(pos)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 1)
        }
    }

    private func positionRow(_ pos: ConsensusDisagreement.Position) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(tint.opacity(0.7))
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                if !pos.model.isEmpty {
                    Text(pos.model)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(tint, in: Capsule())
                        .fixedSize()
                }
                Text(pos.stance)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    /// 「N 家就此表态」摘要文案 —— 立场是自由文本无法可靠聚类,故只给表态家数(诚实不臆断)。
    private func positionsSummary(_ positions: [ConsensusDisagreement.Position]) -> String {
        let named = positions.filter { !$0.model.isEmpty }
        let count = named.isEmpty ? positions.count : named.count
        return "\(count) 家就此各执一词"
    }

    private var agreementsDisclosure: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showAgreements.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showAgreements ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption.weight(.bold))
                    Text("共識 \(analysis.agreements.count) 条")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(agreeColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAgreements {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(analysis.agreements.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(agreeColor.opacity(0.8))
                                .frame(width: 5, height: 5).padding(.top, 6)
                            Text(item)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(agreeColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(.top, 2)
    }

    private func scoreColor(_ score: Int) -> Color {
        if score >= 70 { return agreeColor }
        if score >= 40 { return Color(red: 0.86, green: 0.60, blue: 0.16) }
        return Color(red: 0.82, green: 0.30, blue: 0.26)
    }
}
