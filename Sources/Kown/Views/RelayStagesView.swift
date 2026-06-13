import SwiftUI

/// 接力流水线(MoA)结果视图:把各阶段(起草 → 批判改写 → 润色定稿)按时间线展示,
/// 每站标注用了哪个厂商模型;最后一个有内容的阶段作为「定稿」高亮、默认展开,前序阶段默认折叠。
/// 视觉对齐 `SynthesisCard` / `SelfRevisionCard`(material + 渐变描边)。
struct RelayStagesView: View {
    let result: RelayResult

    private var tint: Color { Color(red: 0.28, green: 0.50, blue: 0.86) }

    /// 最后一个有内容的阶段下标(= 定稿),没有则 nil。
    private var finalIndex: Int? {
        for i in stride(from: result.stages.count - 1, through: 0, by: -1) {
            if !result.stages[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return i }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.turn.up.right.diamond")
                    .font(.caption.weight(.bold)).foregroundStyle(tint)
                Text("接力精炼 · 多模型流水线").font(.caption.weight(.bold)).foregroundStyle(tint)
                Spacer()
                Text("\(result.stages.count) 站").font(.caption2.weight(.bold)).foregroundStyle(tint)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(tint.opacity(0.11), in: Capsule())
            }

            ForEach(Array(result.stages.enumerated()), id: \.element.id) { idx, stage in
                StageRow(stage: stage, isFinal: idx == finalIndex, tint: tint)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.10), .clear],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.24), lineWidth: 1)
        }
    }

    private struct StageRow: View {
        let stage: RelayResult.Stage
        let isFinal: Bool
        let tint: Color
        @State private var expanded: Bool

        init(stage: RelayResult.Stage, isFinal: Bool, tint: Color) {
            self.stage = stage
            self.isFinal = isFinal
            self.tint = tint
            // 定稿默认展开,前序阶段默认折叠(只看定稿的人不被打扰,想看过程能展开)。
            _expanded = State(initialValue: isFinal)
        }

        private var hasText: Bool {
            !stage.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: kindIcon)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(tint)
                            .frame(width: 22, height: 22)
                            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(stage.title).font(.callout.weight(.bold)).foregroundStyle(.primary)
                                if isFinal {
                                    Text("定稿").font(.caption2.weight(.bold)).foregroundStyle(.white)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(tint, in: Capsule())
                                }
                            }
                            Text(stage.modelLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        if stage.error != nil && !hasText {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2.weight(.bold)).foregroundStyle(.orange)
                        }
                        if hasText {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!hasText)

                if let error = stage.error, !hasText {
                    Text(error).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if hasText, expanded {
                    MarkdownText(text: stage.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (isFinal ? tint.opacity(0.08) : Color.secondary.opacity(0.06)),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                if isFinal {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(tint.opacity(0.22), lineWidth: 1)
                }
            }
        }

        private var kindIcon: String {
            switch stage.kind {
            case "draft":    return "pencil.line"
            case "critique": return "arrow.triangle.2.circlepath"
            case "polish":   return "wand.and.stars"
            default:          return "circle.fill"
            }
        }
    }
}
