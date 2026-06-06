import SwiftUI
import Charts

/// Settings → "仪表盘" tab。
/// 把 `UsageStore` 已聚合的用量/成本数据用 Swift Charts 可视化:
/// - 模型别累计成本(横向条形图)
/// - 日别 token 推移(折线 + 面积)
/// - input / output / cached 内訳(条形图)
/// - 合计成本 / 合计 token / 本月成本 的汇总卡
///
/// `UsageStore` 为只读数据源,本视图不写入任何状态(读侧派生)。
struct UsageDashboardView: View {
    @Bindable private var store = UsageStore.shared

    /// 当前显示的统计范围:全部设备汇总 / 仅本机。与 UsageSettingsView 一致。
    @State private var scope: UsageStore.Scope = .all

    // 与 UsageSettingsView 同款配色,保持视觉一致。
    private let tint = Color(red: 0.18, green: 0.52, blue: 0.92)
    private let secondaryTint = Color(red: 0.56, green: 0.40, blue: 0.86)

    // MARK: - 派生数据

    /// 按模型聚合的成本明细(只取有已知金额的,金额降序)。
    private struct ModelCostPoint: Identifiable {
        let id: String          // provider::model 原始 key
        let provider: String
        let model: String
        let cost: Double
        let hasUnknown: Bool
    }

    private var costPoints: [ModelCostPoint] {
        let byModel = store.costByModel(scope: scope)
        return byModel.map { (key, breakdown) in
            let (provider, model) = UsageStore.splitKey(key)
            return ModelCostPoint(
                id: key,
                provider: provider,
                model: model,
                cost: breakdown.knownCostUSD,
                hasUnknown: breakdown.hasUnknown
            )
        }
        .filter { $0.cost > 0 }
        .sorted { $0.cost > $1.cost }
    }

    /// 日别 token 推移点(按日期升序,便于折线从左到右是时间正序)。
    private struct DayPoint: Identifiable {
        let id: String          // yyyy-MM-dd
        let day: String
        let input: Int
        let output: Int
        var total: Int { input + output }
    }

    /// 最多展示最近 30 天,避免横轴过密。
    private var dayPoints: [DayPoint] {
        let days = store.sortedDays(scope: scope).prefix(30)   // 倒序,取最近 30
        return days.map { day -> DayPoint in
            let entries = store.entries(for: day, scope: scope)
            let sum = entries.reduce(UsageEntry()) { acc, e in
                var s = acc; s.input += e.value.input; s.output += e.value.output; return s
            }
            return DayPoint(id: day, day: day, input: sum.input, output: sum.output)
        }
        .sorted { $0.day < $1.day }   // 升序给图表
    }

    /// input / output / cached 三类 token 合计(用于内訳条形图)。
    private struct BreakdownPoint: Identifiable {
        let id: String
        let label: String
        let value: Int
        let color: Color
    }

    private var breakdownPoints: [BreakdownPoint] {
        var cachedTotal = 0
        for bucket in store.snapshot(scope: scope).days.values {
            for entry in bucket.values { cachedTotal += entry.cached }
        }
        let total = store.grandTotal(scope: scope)
        return [
            BreakdownPoint(id: "input", label: "输入", value: total.input, color: .blue),
            BreakdownPoint(id: "output", label: "输出", value: total.output, color: .orange),
            BreakdownPoint(id: "cached", label: "缓存", value: cachedTotal, color: .green)
        ]
    }

    // MARK: - body

    var body: some View {
        #if os(iOS)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(mobileBackground.ignoresSafeArea())
        .scrollIndicators(.hidden)
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .padding(24)
            .frame(maxWidth: 920, alignment: .topLeading)
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        summaryCards
        scopePickerCard
        if #available(macOS 13, iOS 16, *) {
            if hasAnyData {
                costByModelCard
                dailyTrendCard
                breakdownCard
            } else {
                emptyStateCard
            }
        } else {
            // 部署目标已是 macOS 14 / iOS 17,正常走不到这里;留作防御性兜底。
            chartsUnavailableCard
        }
    }

    private var hasAnyData: Bool {
        store.grandTotal(scope: scope).total > 0
    }

    // MARK: - 汇总卡

    private var summaryCards: some View {
        let total = store.grandTotal(scope: scope)
        let cost = store.totalCost(scope: scope)
        let monthCost = store.monthToDateCostUSD(scope: scope)
        let columns = [GridItem(.adaptive(minimum: gridMinTile), spacing: 12)]
        return cardShell(tint: tint) {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("总览", subtitle: "当前范围内的累计 token、成本与本月支出。", icon: "gauge.with.dots.needle.bottom.50percent", color: tint)
                LazyVGrid(columns: columns, spacing: 12) {
                    metricTile(title: "合计 Token",
                               value: formatTokens(total.total),
                               detail: "in \(formatTokens(total.input)) · out \(formatTokens(total.output))",
                               icon: "number",
                               color: tint)
                    metricTile(title: "合计成本",
                               value: CostFormat.usd(cost.knownCostUSD),
                               detail: cost.hasUnknown ? "\(cost.unknownEntryCount) 项价格未知" : "已知单价累计",
                               icon: "dollarsign.circle.fill",
                               color: secondaryTint)
                    metricTile(title: "本月成本",
                               value: CostFormat.usd(monthCost),
                               detail: "当前自然月累计",
                               icon: "calendar.badge.clock",
                               color: .orange)
                    metricTile(title: "调用次数",
                               value: "\(total.callCount)",
                               detail: "LLM 完成响应后记录",
                               icon: "bolt.horizontal.fill",
                               color: .green)
                }
            }
        }
    }

    private var scopePickerCard: some View {
        cardShell(tint: tint) {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("查看范围", subtitle: "在所有设备汇总和本机记录之间切换,不影响实际数据。", icon: "scope", color: tint)
                Picker("范围", selection: $scope) {
                    Text("全部设备").tag(UsageStore.Scope.all)
                    Text("仅本机").tag(UsageStore.Scope.thisDevice)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    // MARK: - 图表:模型别累计成本(横向条形图)

    @available(macOS 13, iOS 16, *)
    private var costByModelCard: some View {
        let points = costPoints
        return cardShell(tint: secondaryTint) {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("模型成本对比", subtitle: "各模型累计已知成本(美元)。仅展示有已知单价的模型。", icon: "chart.bar.fill", color: secondaryTint)
                if points.isEmpty {
                    placeholderRow("暂无可计价的模型成本")
                } else {
                    Chart(points) { p in
                        BarMark(
                            x: .value("成本", p.cost),
                            y: .value("模型", p.model)
                        )
                        .foregroundStyle(providerColor(p.provider).gradient)
                        .annotation(position: .trailing, alignment: .leading) {
                            Text(CostFormat.usd(p.cost))
                                .font(.caption2.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .chartXAxis {
                        AxisMarks(position: .bottom)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { _ in
                            AxisValueLabel()
                                .font(.caption2)
                        }
                    }
                    .frame(height: chartHeight(rows: points.count))
                }
            }
        }
    }

    // MARK: - 图表:日别 token 推移(折线 + 面积)

    @available(macOS 13, iOS 16, *)
    private var dailyTrendCard: some View {
        let points = dayPoints
        return cardShell(tint: tint) {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("每日 Token 推移", subtitle: "最近 \(min(points.count, 30)) 天 input / output token 走势。", icon: "chart.line.uptrend.xyaxis", color: tint)
                if points.isEmpty {
                    placeholderRow("暂无每日记录")
                } else {
                    Chart {
                        ForEach(points) { p in
                            AreaMark(
                                x: .value("日期", p.day),
                                y: .value("Token", p.total)
                            )
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [tint.opacity(0.28), tint.opacity(0.02)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .interpolationMethod(.catmullRom)
                        }
                        ForEach(points) { p in
                            LineMark(
                                x: .value("日期", p.day),
                                y: .value("Token", p.total)
                            )
                            .foregroundStyle(tint)
                            .interpolationMethod(.catmullRom)
                            .symbol(Circle().strokeBorder(lineWidth: 1.4))
                            .symbolSize(28)
                        }
                    }
                    .chartXAxis {
                        // 横轴标签太密会糊成一团,自动间隔取样。
                        AxisMarks(values: .automatic(desiredCount: 5)) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let raw = value.as(String.self) {
                                    Text(shortDay(raw))
                                        .font(.caption2)
                                }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let n = value.as(Int.self) {
                                    Text(formatTokens(n)).font(.caption2)
                                }
                            }
                        }
                    }
                    .frame(height: 200)
                }
            }
        }
    }

    // MARK: - 图表:input / output / cached 内訳

    @available(macOS 13, iOS 16, *)
    private var breakdownCard: some View {
        let points = breakdownPoints
        let total = store.grandTotal(scope: scope)
        return cardShell(tint: secondaryTint) {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("Token 内訳", subtitle: "输入 / 输出 / 命中缓存 的 token 占比。", icon: "square.stack.3d.up.fill", color: secondaryTint)
                if total.total == 0 {
                    placeholderRow("暂无 token 记录")
                } else {
                    Chart(points) { p in
                        BarMark(
                            x: .value("类型", p.label),
                            y: .value("Token", p.value)
                        )
                        .foregroundStyle(p.color.gradient)
                        .annotation(position: .top) {
                            Text(formatTokens(p.value))
                                .font(.caption2.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let n = value.as(Int.self) {
                                    Text(formatTokens(n)).font(.caption2)
                                }
                            }
                        }
                    }
                    .frame(height: 180)

                    // 内訳数字行(图表下方,补充精确值)
                    HStack(spacing: 8) {
                        ForEach(points) { p in
                            tokenBadge(label: p.label, value: p.value, color: p.color)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: - 空状态 / 兜底

    private var emptyStateCard: some View {
        cardShell(tint: tint) {
            VStack(spacing: 12) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 70, height: 70)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                Text("还没有可视化数据")
                    .font(.headline)
                Text("发送一条消息后,token 用量与成本会自动汇总到仪表盘。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(34)
        }
    }

    private var chartsUnavailableCard: some View {
        cardShell(tint: .orange) {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("图表需要更新系统", subtitle: "可视化图表需 macOS 13 / iOS 16 及以上。请到「Token 用量」查看列表形式的统计。", icon: "exclamationmark.triangle.fill", color: .orange)
            }
        }
    }

    private func placeholderRow(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 80)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - 复用样式片段(与 UsageSettingsView 一致的意匠)

    private func sectionHeader(_ title: String, subtitle: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func metricTile(title: String, value: String, detail: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .monospacedDigit()
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(color.opacity(0.18), lineWidth: 1)
        }
    }

    private func tokenBadge(label: String, value: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
            Text(formatTokens(value))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.10), in: Capsule())
        .overlay { Capsule().strokeBorder(color.opacity(0.16), lineWidth: 1) }
    }

    @ViewBuilder
    private func cardShell<Content: View>(tint: Color, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(cardPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                        .fill(.regularMaterial)
                    RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.08), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .overlay {
                RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                    .strokeBorder(tint.opacity(0.16), lineWidth: 1)
            }
    }

    #if os(iOS)
    private var mobileBackground: some View {
        ZStack {
            Color.platformWindowBackground
            RadialGradient(
                colors: [tint.opacity(0.12), Color.clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 420
            )
            RadialGradient(
                colors: [secondaryTint.opacity(0.10), Color.clear],
                center: .bottomTrailing,
                startRadius: 60,
                endRadius: 540
            )
        }
    }
    #endif

    private var cardPadding: CGFloat {
        #if os(iOS)
        return 14
        #else
        return 18
        #endif
    }

    private var cardCornerRadius: CGFloat {
        #if os(iOS)
        return 18
        #else
        return 22
        #endif
    }

    private var gridMinTile: CGFloat {
        #if os(iOS)
        return 140
        #else
        return 150
        #endif
    }

    /// 条形图高度随行数自适应(每行约 34pt,留出上下边距),封顶避免太高。
    private func chartHeight(rows: Int) -> CGFloat {
        let h = CGFloat(max(rows, 1)) * 34 + 24
        return min(max(h, 120), 360)
    }

    // MARK: - utils

    private func providerColor(_ provider: String) -> Color {
        switch provider {
        case ProviderKind.openAICompatible.rawValue: return Color(red: 0.06, green: 0.64, blue: 0.50)
        case ProviderKind.anthropic.rawValue:        return Color(red: 0.83, green: 0.38, blue: 0.18)
        case ProviderKind.gemini.rawValue:           return Color(red: 0.26, green: 0.52, blue: 0.96)
        case ProviderKind.cliCommand.rawValue:       return Color(red: 0.55, green: 0.45, blue: 0.78)
        default:                                     return tint
        }
    }

    /// "yyyy-MM-dd" → "MM-dd",缩短横轴标签。
    private func shortDay(_ raw: String) -> String {
        let parts = raw.split(separator: "-")
        if parts.count == 3 { return "\(parts[1])-\(parts[2])" }
        return raw
    }

    private func formatTokens(_ n: Int) -> String {
        if n < 1_000 { return "\(n)" }
        if n < 1_000_000 { return String(format: "%.1fK", Double(n) / 1000) }
        return String(format: "%.2fM", Double(n) / 1_000_000)
    }
}
