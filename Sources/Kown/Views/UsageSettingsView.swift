import SwiftUI

/// Settings → "Token 用量" tab。
/// 按天分组显示每个 (provider, model) 的 input / output / total tokens + 调用次数。
struct UsageSettingsView: View {
    @Bindable private var store = UsageStore.shared
    @State private var confirmReset = false
    /// 当前显示的统计范围:全部设备汇总 / 仅本机
    @State private var scope: UsageStore.Scope = .all

    private let tint = Color(red: 0.24, green: 0.63, blue: 0.36)
    private let secondaryTint = Color(red: 0.08, green: 0.70, blue: 0.78)

    private var days: [String] { store.sortedDays(scope: scope) }

    var body: some View {
        #if os(iOS)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                heroCard
                scopePickerCard
                if days.isEmpty {
                    emptyStateCard
                } else {
                    ForEach(days, id: \.self) { day in
                        dayCard(day)
                    }
                }
                resetCard
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(mobileSettingsBackground.ignoresSafeArea())
        .scrollIndicators(.hidden)
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heroCard
                scopePickerCard
                if days.isEmpty {
                    emptyStateCard
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(days, id: \.self) { day in
                            dayCard(day)
                        }
                    }
                }
                resetCard
            }
            .padding(24)
            .frame(maxWidth: 920, alignment: .topLeading)
        }
        #endif
    }

    // MARK: - Hero

    #if os(iOS)
    private var heroSection: some View {
        Section {
            heroCard
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                .listRowBackground(Color.clear)
        }
    }
    #endif

    private var heroCard: some View {
        let total = store.grandTotal(scope: scope)
        let devices = max(store.deviceCount, 1)
        let isThisDeviceOnly = (scope == .thisDevice)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                iconTile("chart.bar.xaxis", tint: tint, secondary: secondaryTint)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text("Token 用量")
                            .font(.system(.title2, design: .rounded).weight(.bold))
                        statusBadge(isThisDeviceOnly ? "仅本机" : "全部设备",
                                    icon: isThisDeviceOnly ? "desktopcomputer" : "externaldrive.connected.to.line.below",
                                    color: isThisDeviceOnly ? .secondary : tint)
                    }
                    Text("按天 + 模型统计 input / output token 和调用次数,方便估算成本并观察不同模型的使用节奏。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(formatTokens(total.total))
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .monospacedDigit()
                    Text("total tokens")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                metricTile(title: "调用次数",
                           value: "\(total.callCount)",
                           detail: "LLM 完成响应后记录",
                           icon: "bolt.horizontal.fill",
                           color: tint)
                metricTile(title: "统计天数",
                           value: "\(days.count)",
                           detail: days.first.map { "最近 \(prettyDate($0))" } ?? "暂无记录",
                           icon: "calendar",
                           color: secondaryTint)
                metricTile(title: "设备",
                           value: isThisDeviceOnly ? "本机" : "\(devices)",
                           detail: isThisDeviceOnly ? "只看当前设备文件" : "跨设备 usage 文件汇总",
                           icon: isThisDeviceOnly ? "laptopcomputer" : "icloud.fill",
                           color: isThisDeviceOnly ? .secondary : .blue)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(heroBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: tint.opacity(0.09), radius: 22, x: 0, y: 12)
    }

    // MARK: - scope picker

    private var scopePicker: some View {
        Picker("范围", selection: $scope) {
            Text("全部设备").tag(UsageStore.Scope.all)
            Text("仅本机").tag(UsageStore.Scope.thisDevice)
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var scopePickerSection: some View {
        Section("查看范围") { scopePicker }
    }

    private var scopePickerCard: some View {
        cardShell(tint: tint) {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("查看范围", subtitle: "在所有设备汇总和本机记录之间切换,不影响实际数据。", icon: "scope", color: tint)
                scopePicker
                summaryRow
            }
        }
    }

    // MARK: - 共用片段

    private func daySectionContent(_ day: String) -> some View {
        let entries = store.entries(for: day, scope: scope)
        let dayTotal = entries.reduce(UsageEntry()) { sum, e in
            var s = sum; s.input += e.value.input; s.output += e.value.output
            s.callCount += e.value.callCount; return s
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                statusBadge("当日合计", icon: "sum", color: tint)
                Spacer(minLength: 0)
                Text("\(formatTokens(dayTotal.total))")
                    .font(.callout.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text("· \(dayTotal.callCount) 次调用")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ForEach(entries, id: \.key) { entry in
                modelRow(key: entry.key, entry: entry.value)
            }
        }
    }

    private func modelRow(key: String, entry: UsageEntry) -> some View {
        let (provider, model) = UsageStore.splitKey(key)
        #if os(iOS)
        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Image(systemName: "cube.transparent.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(providerColor(provider))
                    .frame(width: 30, height: 30)
                    .background(providerColor(provider).opacity(0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(model)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(provider)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatTokens(entry.total))
                        .font(.callout.weight(.bold))
                        .monospacedDigit()
                    Text("\(entry.callCount) 次")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            HStack(spacing: 7) {
                tokenBadge(label: "in", value: entry.input, color: .blue)
                tokenBadge(label: "out", value: entry.output, color: .orange)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        #else
        return HStack(spacing: 10) {
            Image(systemName: "cube.transparent.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(providerColor(provider))
                .frame(width: 28, height: 28)
                .background(providerColor(provider).opacity(0.11), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(model)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(provider)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            tokenBadge(label: "in", value: entry.input, color: .blue)
            tokenBadge(label: "out", value: entry.output, color: .orange)
            Text("\(formatTokens(entry.total))")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 64, alignment: .trailing)
            Text("\(entry.callCount)×")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .frame(minWidth: 30, alignment: .trailing)
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        #endif
    }

    private func tokenBadge(label: String, value: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(.caption2, design: .monospaced).weight(.bold))
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

    // MARK: - 总览

    private var summaryRow: some View {
        let total = store.grandTotal(scope: scope)
        let devices = store.deviceCount
        let isThisDeviceOnly = (scope == .thisDevice)
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(isThisDeviceOnly ? "本机累计" : "全部累计")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 6) {
                    Text("\(total.callCount) 次调用 · \(days.count) 天")
                    if !isThisDeviceOnly, devices > 1 {
                        Text("· \(devices) 台设备")
                            .foregroundStyle(tint)
                    }
                    if isThisDeviceOnly {
                        Text("· 仅本机")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(formatTokens(total.total))
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                HStack(spacing: 6) {
                    Text("in \(formatTokens(total.input))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.blue)
                    Text("out \(formatTokens(total.output))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                .monospacedDigit()
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func dayCard(_ day: String) -> some View {
        cardShell(tint: tint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(prettyDate(day))
                        .font(.headline)
                    Spacer()
                    Text("\(store.entries(for: day, scope: scope).count) 个模型")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.10), in: Capsule())
                }
                daySectionContent(day)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 70, height: 70)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            Text("还没有用量记录")
                .font(.headline)
            Text("发送一条消息后,模型的 token 用量会自动记录到这里。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(34)
    }

    private var emptyStateCard: some View {
        cardShell(tint: tint) { emptyState }
    }

    @ViewBuilder
    private var resetSection: some View {
        Section {
            Button("清空所有用量记录", role: .destructive) {
                confirmReset = true
            }
        }
        .confirmationDialog("确定要清空全部 token 用量记录?", isPresented: $confirmReset) {
            Button("清空", role: .destructive) { store.reset() }
            Button("取消", role: .cancel) {}
        }
    }

    private var resetCard: some View {
        cardShell(tint: .red) {
            #if os(iOS)
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("管理", subtitle: "清空只会删除本机产生的用量文件,其他设备记录不会被本机覆盖。", icon: "trash", color: .red)
                Button("清空所有用量记录", role: .destructive) {
                    confirmReset = true
                }
                .buttonStyle(.bordered)
            }
            #else
            HStack(spacing: 12) {
                sectionHeader("管理", subtitle: "清空只会删除本机产生的用量文件,其他设备记录不会被本机覆盖。", icon: "trash", color: .red)
                Spacer(minLength: 0)
                Button("清空所有用量记录", role: .destructive) {
                    confirmReset = true
                }
                .buttonStyle(.bordered)
            }
            #endif
        }
        .confirmationDialog("确定要清空全部 token 用量记录?", isPresented: $confirmReset) {
            Button("清空", role: .destructive) { store.reset() }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - Styling helpers

    #if os(iOS)
    private var mobileSettingsBackground: some View {
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

    private var heroBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.16), secondaryTint.opacity(0.10), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }

    private func iconTile(_ symbol: String, tint: Color, secondary: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.95), secondary.opacity(0.78)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 58, height: 58)
        .shadow(color: tint.opacity(0.20), radius: 14, x: 0, y: 8)
    }

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
                .minimumScaleFactor(0.78)
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

    private func statusBadge(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
            .overlay { Capsule().strokeBorder(color.opacity(0.18), lineWidth: 1) }
            .fixedSize()
    }

    @ViewBuilder
    private func cardShell<Content: View>(tint: Color, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.regularMaterial)
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
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
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(tint.opacity(0.16), lineWidth: 1)
            }
    }

    // MARK: - utils

    private func providerColor(_ provider: String) -> Color {
        switch provider {
        case ProviderKind.openAICompatible.rawValue: return Color(red: 0.06, green: 0.64, blue: 0.50)
        case ProviderKind.anthropic.rawValue:        return Color(red: 0.83, green: 0.38, blue: 0.18)
        case ProviderKind.gemini.rawValue:           return Color(red: 0.26, green: 0.52, blue: 0.96)
        case ProviderKind.cliCommand.rawValue:       return Color(red: 0.55, green: 0.45, blue: 0.78)
        default:                                     return .secondary
        }
    }

    private func prettyDate(_ raw: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: raw) else { return raw }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "今天 · \(raw)" }
        if cal.isDateInYesterday(d) { return "昨天 · \(raw)" }
        return raw
    }

    private func formatTokens(_ n: Int) -> String {
        if n < 1_000 { return "\(n)" }
        if n < 1_000_000 { return String(format: "%.1fK", Double(n) / 1000) }
        return String(format: "%.2fM", Double(n) / 1_000_000)
    }
}
