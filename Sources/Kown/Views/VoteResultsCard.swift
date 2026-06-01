import SwiftUI

/// Council 投票打分结果卡:按总分排名,每行四维度小条 + 总分,底部一句总评。
struct VoteResultsCard: View {
    let vote: CouncilVote
    /// providerID(uuidString) → 展示名(从 turn.providerSnapshot 取)。
    let names: [String: String]

    private var tint: Color { Color(red: 0.92, green: 0.62, blue: 0.16) }

    private var ranked: [(id: String, score: CouncilVote.Score)] {
        vote.scores.map { (id: $0.key, score: $0.value) }
            .sorted { $0.score.total > $1.score.total }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.9), tint.opacity(0.5)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "checklist")
                        .foregroundStyle(.white).font(.system(size: 14, weight: .bold))
                }
                .frame(width: 34, height: 34)
                Text("投票打分")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                Spacer()
                Text("准确·完整·可执行·清晰")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(ranked.enumerated()), id: \.element.id) { idx, item in
                row(rank: idx + 1, name: names[item.id] ?? "模型", score: item.score)
            }

            if !vote.rationale.isEmpty {
                Text(vote.rationale)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.10), .clear],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(tint.opacity(0.28), lineWidth: 1)
        }
    }

    private func row(rank: Int, name: String, score: CouncilVote.Score) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("#\(rank)")
                    .font(.caption2.weight(.black).monospacedDigit())
                    .foregroundStyle(rank == 1 ? tint : .secondary)
                Text(name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text("\(score.total)")
                    .font(.callout.weight(.bold).monospacedDigit())
                    .foregroundStyle(tint)
                Text("/40").font(.caption2).foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                dim("准", score.accuracy)
                dim("整", score.completeness)
                dim("行", score.actionability)
                dim("晰", score.clarity)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func dim(_ label: String, _ v: Int) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(tint.opacity(0.8))
                        .frame(width: geo.size.width * CGFloat(v) / 10.0)
                }
            }
            .frame(height: 5)
            Text("\(v)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
