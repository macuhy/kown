import SwiftUI

/// 答案差异分析面板:把一轮里各家回答的「共識(绿)/ 分歧(橙)」分组展示,可折叠。
/// Compare / Council 通用:点「分析分歧」后,turn.consensusAnalysis 有值即渲染本卡。
struct ConsensusPanel: View {
    let analysis: ConsensusAnalysis

    @State private var collapsed = false

    private var tint: Color { Color(red: 0.45, green: 0.4, blue: 0.85) }
    private var agreeColor: Color { Color(red: 0.16, green: 0.62, blue: 0.40) }
    private var disagreeColor: Color { Color(red: 0.86, green: 0.45, blue: 0.16) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !collapsed {
                // 一致度徽章(结构化分析才有 score;纯文本退路不显示)。
                if let score = analysis.agreementScore {
                    agreementBadge(score)
                }
                if !analysis.agreements.isEmpty {
                    section(title: "共識", systemImage: "checkmark.seal.fill",
                            color: agreeColor, items: analysis.agreements)
                }
                // 结构化分歧点(各模型立场卡片)优先;否则退回纯文本分歧列表。
                if let points = analysis.disagreementPoints, !points.isEmpty {
                    disagreementPointsSection(points)
                } else if !analysis.disagreements.isEmpty {
                    section(title: "分歧", systemImage: "arrow.triangle.branch",
                            color: disagreeColor, items: analysis.disagreements)
                }
                if analysis.agreements.isEmpty && analysis.disagreements.isEmpty
                    && (analysis.disagreementPoints?.isEmpty ?? true) {
                    Text("未发现明显的共識或分歧。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { collapsed.toggle() }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.9), tint.opacity(0.5)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "square.split.2x1.fill")
                        .foregroundStyle(.white).font(.system(size: 13, weight: .bold))
                }
                .frame(width: 34, height: 34)
                Text("共識与分歧")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(.primary)
                Spacer()
                // 折叠时也能一眼看到一致度。
                if collapsed, let score = analysis.agreementScore {
                    Text("\(score)% 一致")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(scoreColor(score))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(scoreColor(score).opacity(0.14), in: Capsule())
                }
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    /// 一致度分档配色:高(绿)/ 中(橙)/ 低(红)。
    private func scoreColor(_ score: Int) -> Color {
        if score >= 70 { return agreeColor }
        if score >= 40 { return Color(red: 0.86, green: 0.60, blue: 0.16) }
        return Color(red: 0.82, green: 0.30, blue: 0.26)
    }

    private func scoreLabel(_ score: Int) -> String {
        if score >= 70 { return "高度一致" }
        if score >= 40 { return "部分一致" }
        return "分歧较大"
    }

    /// 一致度徽章:进度条 + 百分比 + 分档文案。
    private func agreementBadge(_ score: Int) -> some View {
        let color = scoreColor(score)
        return HStack(spacing: 10) {
            ZStack {
                Circle().stroke(color.opacity(0.18), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: CGFloat(max(0, min(100, score))) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(score)")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text("一致度 \(score)%")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text(scoreLabel(score))
                    .font(.caption)
                    .foregroundStyle(color)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(color.opacity(0.18), lineWidth: 1)
        }
    }

    /// 分歧点卡片组:每个分歧点一张卡,卡内列各模型立场。
    private func disagreementPointsSection(_ points: [ConsensusDisagreement]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(disagreeColor)
                Text("分歧点")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(disagreeColor)
            }
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                disagreementCard(point)
            }
        }
    }

    private func disagreementCard(_ point: ConsensusDisagreement) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(point.point)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if !point.positions.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(point.positions.enumerated()), id: \.offset) { _, pos in
                        HStack(alignment: .top, spacing: 6) {
                            if !pos.model.isEmpty {
                                Text(pos.model)
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(disagreeColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(disagreeColor.opacity(0.12), in: Capsule())
                                    .fixedSize()
                            }
                            Text(pos.stance)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(disagreeColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(disagreeColor.opacity(0.16), lineWidth: 1)
        }
    }

    private func section(title: String, systemImage: String, color: Color, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(color)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(color.opacity(0.8))
                        .frame(width: 5, height: 5)
                        .padding(.top, 6)
                    Text(item)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// 「分析分歧」入口 + 结果面板的组合件 —— Compare / Council 共用,避免两处重复按钮逻辑。
/// - 已有分析结果 → 直接展示 `ConsensusPanel`(并允许「重新分析」)。
/// - 没有结果 → 展示一颗 opt-in 按钮(成本考量,按需触发);加载中显示进度;失败显示错误 + 重试。
struct ConsensusSection: View {
    let analysis: ConsensusAnalysis?
    let isAnalyzing: Bool
    let error: String?
    let onAnalyze: () -> Void

    /// 结构化分歧点存在时,在「共識与分歧」面板与「分歧雷达」之间切换的视图模式。
    private enum ViewKind { case panel, radar }
    @State private var viewKind: ViewKind = .panel

    private var tint: Color { Color(red: 0.45, green: 0.4, blue: 0.85) }

    /// 分析含结构化分歧点时才提供「分歧雷达」切换(雷达靠 disagreementPoints 渲染)。
    private var hasRadar: Bool {
        !(analysis?.disagreementPoints?.isEmpty ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let analysis {
                if hasRadar {
                    radarToggle
                }
                if hasRadar && viewKind == .radar {
                    DisagreementRadarView(analysis: analysis)
                } else {
                    ConsensusPanel(analysis: analysis)
                }
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: onAnalyze) {
                HStack(spacing: 6) {
                    if isAnalyzing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "square.split.2x1.fill")
                    }
                    Text(isAnalyzing ? "分析中…" : (analysis == nil ? "分析分歧" : "重新分析"))
                        .font(.callout.weight(.medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(tint.opacity(0.12), in: Capsule())
                .foregroundStyle(tint)
            }
            .buttonStyle(.plain)
            .disabled(isAnalyzing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 「共識与分歧 / 分歧雷达」分段切换 —— 仅结构化分歧点存在时出现。
    private var radarToggle: some View {
        HStack(spacing: 0) {
            segButton("共識与分歧", systemImage: "square.split.2x1.fill", kind: .panel)
            segButton("分歧雷达", systemImage: "dot.radiowaves.left.and.right", kind: .radar)
        }
        .padding(3)
        .background(Color.secondary.opacity(0.10), in: Capsule())
    }

    private func segButton(_ title: String, systemImage: String, kind: ViewKind) -> some View {
        let selected = viewKind == kind
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) { viewKind = kind }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(selected ? Color.white : .secondary)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background {
                    if selected { Capsule().fill(tint) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
