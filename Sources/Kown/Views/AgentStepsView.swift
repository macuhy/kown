import SwiftUI

/// Agent 步骤可视化:把一次回答里的工具调用按「第几轮」分组,渲染成可折叠的步骤树。
/// 每步显示 工具名 + 参数摘要 + 状态(转圈 / ✓ / ✗)+ 结果摘要。数据来自 `ResponseState.toolSteps`。
struct AgentStepsView: View {
    let steps: [ToolStep]
    @State private var collapsed = false

    private var tint: Color { Color(red: 0.36, green: 0.45, blue: 0.92) }

    /// 按 round 分组,round 升序。
    private var rounds: [(round: Int, steps: [ToolStep])] {
        let grouped = Dictionary(grouping: steps, by: { $0.round })
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !collapsed {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rounds, id: \.round) { group in
                        roundBlock(index: group.round, steps: group.steps)
                    }
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.opacity(0.16), lineWidth: 1)
        }
    }

    private var anyRunning: Bool { steps.contains { $0.status == .running } }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { collapsed.toggle() }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "gearshape.2.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                Text(anyRunning ? "正在执行工具…" : "工具步骤")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                Text("\(steps.count) 步")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 0)
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func roundBlock(index: Int, steps: [ToolStep]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("第 \(index + 1) 轮")
                .font(.caption2.weight(.black))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(tint.opacity(0.10), in: Capsule())
            ForEach(steps) { step in
                stepRow(step)
            }
        }
    }

    private func stepRow(_ step: ToolStep) -> some View {
        HStack(alignment: .top, spacing: 8) {
            statusIcon(step.status)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: step.iconName)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(tint)
                    Text(step.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                if !step.argsSummary.isEmpty {
                    Text(step.argsSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let result = step.resultSummary, !result.isEmpty {
                    Text(result)
                        .font(.caption2)
                        .foregroundStyle(step.status == .error ? .red : .secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: ToolStep.Status) -> some View {
        switch status {
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "xmark.octagon.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.red)
        }
    }
}
