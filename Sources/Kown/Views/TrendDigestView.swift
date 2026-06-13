import SwiftUI

/// [趋势洞察] 一个订阅任务的「走势」面板:
/// 上半部把历次运行摘要铺成时间线(最新在上),下半部一键让 LLM 基于整串历史产出趋势报告。
/// 纯展示 + 一次性调用,自管 @State(报告/加载/错误),不落盘、不碰发送管线。
struct TrendDigestView: View {
    let task: ScheduledTask
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var report: String?
    @State private var generating = false
    @State private var errorText: String?

    private var tint: Color { Color(red: 0.20, green: 0.56, blue: 0.78) }
    private var warmTint: Color { Color(red: 0.92, green: 0.55, blue: 0.22) }

    /// 历次运行(最新在前)。
    private var history: [DatedDigest] {
        (task.runDigestHistory ?? []).sorted { $0.date > $1.date }
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            content
                .navigationTitle("走势洞察")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
                .toolbarBackground(.hidden, for: .navigationBar)
        }
        #else
        VStack(spacing: 0) {
            titleBar
            Rectangle().fill(KownTheme.hairline).frame(height: 1)
            content
        }
        .frame(minWidth: 520, idealWidth: 600, maxWidth: 680, minHeight: 560, idealHeight: 660)
        .background(backdrop)
        #endif
    }

    private var titleBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("走势洞察")
                    .font(.headline.weight(.black))
                Text(taskTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.black))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color.platformControlBackground.opacity(0.62), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                if history.isEmpty {
                    emptyState
                } else {
                    trendSection
                    timelineSection
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .background(backdrop)
    }

    private var hero: some View {
        KownGlassCard(tint: tint, cornerRadius: 24, intensity: 0.11) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(LinearGradient(colors: [tint, warmTint.opacity(0.85)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 24, weight: .black))
                        .foregroundStyle(.white)
                }
                .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 5) {
                    Text("\(history.count) 次运行记录")
                        .font(.title3.weight(.black))
                        .monospacedDigit()
                    Text(history.count >= 2
                         ? "盯了这件事一段时间,让 Kown 看看整体往哪走 —— 报告趋势,而不是每天的孤立快照。"
                         : "再多跑几次,攒够样本就能看出走势。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 30, weight: .black))
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 64)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text("还没有运行记录")
                .font(.headline.weight(.black))
            Text("这个任务每次跑完拿到结果,都会在这里留下一条;攒够两条就能分析走势。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: 趋势报告区(一键生成)

    @ViewBuilder
    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("趋势报告")
                        .font(.headline.weight(.black))
                    Text("把历次摘要按时间喂给模型,提炼出变化与走向。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                generateButton
            }

            if generating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在分析走势…")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(inputBackground)
            } else if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else if let report {
                VStack(alignment: .leading, spacing: 8) {
                    MarkdownText(text: report)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(inputBackground)
            } else {
                Text(history.count >= 2
                     ? "点「生成趋势」让模型分析这 \(history.count) 次记录的走势。"
                     : "至少需要两次运行记录才能分析走势。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(inputBackground)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(tint.opacity(0.15), lineWidth: 1)
        }
    }

    private var generateButton: some View {
        Button {
            runTrend()
        } label: {
            Label(report == nil ? "生成趋势" : "重新生成", systemImage: "wand.and.stars")
                .font(.caption.weight(.black))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(
                    LinearGradient(colors: [tint, warmTint.opacity(0.92)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(generating || history.count < 2)
        .opacity((generating || history.count < 2) ? 0.5 : 1)
        .accessibilityLabel("生成趋势报告")
    }

    // MARK: 时间线区

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.caption.weight(.black))
                    .foregroundStyle(warmTint)
                Text("运行时间线")
                    .font(.headline.weight(.black))
                Spacer(minLength: 0)
                Text("\(history.count) 条")
                    .font(.caption.weight(.black))
                    .monospacedDigit()
                    .foregroundStyle(warmTint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(warmTint.opacity(0.11), in: Capsule(style: .continuous))
            }

            VStack(spacing: 0) {
                ForEach(Array(history.enumerated()), id: \.element.id) { idx, item in
                    timelineRow(item, isLatest: idx == 0, isLast: idx == history.count - 1)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(warmTint.opacity(0.13), lineWidth: 1)
        }
    }

    private func timelineRow(_ item: DatedDigest, isLatest: Bool, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle()
                    .fill(isLatest ? tint : warmTint.opacity(0.6))
                    .frame(width: 11, height: 11)
                    .overlay { Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 1) }
                if !isLast {
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 11)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(dateText(item.date))
                        .font(.caption.weight(.black))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    if isLatest {
                        Text("最新")
                            .font(.caption2.weight(.black))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(tint.opacity(0.12), in: Capsule(style: .continuous))
                    }
                    Spacer(minLength: 0)
                }
                Text(item.digest)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.bottom, isLast ? 0 : 14)
        }
    }

    // MARK: 触发

    private func runTrend() {
        guard !generating, history.count >= 2 else { return }
        generating = true
        errorText = nil
        let snapshot = task
        let provider = viewModel.chairProvider
            ?? viewModel.providers.first(where: { $0.enabled && !$0.kind.isCLI })
        Task { @MainActor in
            defer { generating = false }
            let result = await TrendDigestService.trendReport(for: snapshot, provider: provider)
            switch result {
            case .success(let text): report = text
            case .failure(let err):  errorText = err.errorDescription ?? "趋势分析失败"
            }
        }
    }

    private var taskTitle: String {
        let t = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        if task.isBriefing { return "晨间简报" }
        if task.isAgent { return "Agent 任务" }
        return "定时任务"
    }

    private func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.month(.twoDigits).day(.twoDigits)
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.platformControlBackground.opacity(0.55))
    }

    private var backdrop: some View {
        ZStack {
            Color.platformWindowBackground
            RadialGradient(colors: [tint.opacity(0.14), Color.clear],
                           center: .topLeading, startRadius: 10, endRadius: 440)
            RadialGradient(colors: [warmTint.opacity(0.12), Color.clear],
                           center: .bottomTrailing, startRadius: 20, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}
