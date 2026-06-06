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
                if !analysis.agreements.isEmpty {
                    section(title: "共識", systemImage: "checkmark.seal.fill",
                            color: agreeColor, items: analysis.agreements)
                }
                if !analysis.disagreements.isEmpty {
                    section(title: "分歧", systemImage: "arrow.triangle.branch",
                            color: disagreeColor, items: analysis.disagreements)
                }
                if analysis.agreements.isEmpty && analysis.disagreements.isEmpty {
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
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
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

    private var tint: Color { Color(red: 0.45, green: 0.4, blue: 0.85) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let analysis {
                ConsensusPanel(analysis: analysis)
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
}
