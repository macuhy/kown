import SwiftUI

/// 设置 ▸ 排行榜:Compare 模式裁判判定累计出的「模型胜率榜」。
/// 按胜率降序排名,展示胜/负/平、对战数与胜率。可清空。
struct LeaderboardView: View {
    private var store = ModelLeaderboardStore.shared
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                let standings = store.standings
                if standings.isEmpty {
                    emptyState
                } else {
                    header(count: standings.count)
                    ForEach(Array(standings.enumerated()), id: \.element.id) { idx, standing in
                        row(rank: idx + 1, standing: standing)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .confirmationDialog("清空全部战绩?不可恢复。", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { store.reset() }
            Button("取消", role: .cancel) { }
        }
    }

    private func header(count: Int) -> some View {
        HStack {
            Text("\(count) 个模型 · \(store.totalMatches) 场评判")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button(role: .destructive) { confirmClear = true } label: {
                Label("清空", systemImage: "trash").font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "trophy")
                .font(.system(size: 30, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 62, height: 62)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text("还没有战绩").font(.headline.weight(.bold))
            Text("在 Compare 模式两家回答完成后,点「让裁判评判」即可让裁判判出胜者,胜负会累计到这里。")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func row(rank: Int, standing: ModelLeaderboardStore.Standing) -> some View {
        let rec = standing.record
        return HStack(spacing: 12) {
            rankBadge(rank)

            VStack(alignment: .leading, spacing: 4) {
                Text(standing.model)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .lineLimit(1).truncationMode(.middle)
                Text(standing.providerKind?.displayName ?? "未知厂商")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                Text(winRateText(rec.winRate))
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(rateColor(rec.winRate))
                    .monospacedDigit()
                recordChips(rec)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func rankBadge(_ rank: Int) -> some View {
        let tint = rankTint(rank)
        return Text("\(rank)")
            .font(.system(.subheadline, design: .rounded).weight(.heavy))
            .monospacedDigit()
            .foregroundStyle(rank <= 3 ? Color.white : Color.secondary)
            .frame(width: 30, height: 30)
            .background(
                Circle().fill(rank <= 3 ? tint : Color.secondary.opacity(0.12))
            )
    }

    private func recordChips(_ rec: ModelLeaderboardStore.Record) -> some View {
        HStack(spacing: 6) {
            chip("\(rec.wins) 胜", color: .green)
            chip("\(rec.losses) 负", color: .red)
            if rec.draws > 0 {
                chip("\(rec.draws) 平", color: .secondary)
            }
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }

    private func winRateText(_ rate: Double) -> String {
        String(format: "%.0f%%", rate * 100)
    }

    private func rateColor(_ rate: Double) -> Color {
        if rate >= 0.6 { return .green }
        if rate >= 0.4 { return .orange }
        return .red
    }

    private func rankTint(_ rank: Int) -> Color {
        switch rank {
        case 1:  return Color(red: 0.92, green: 0.70, blue: 0.18) // 金
        case 2:  return Color(red: 0.62, green: 0.66, blue: 0.72) // 银
        case 3:  return Color(red: 0.78, green: 0.50, blue: 0.30) // 铜
        default: return .secondary
        }
    }
}
