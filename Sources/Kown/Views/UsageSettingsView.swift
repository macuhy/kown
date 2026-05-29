import SwiftUI

/// Settings → "Token 用量" tab。
/// 按天分组显示每个 (provider, model) 的 input / output / total tokens + 调用次数。
struct UsageSettingsView: View {
    @Bindable private var store = UsageStore.shared
    @State private var confirmReset = false
    /// 当前显示的统计范围:全部设备汇总 / 仅本机
    @State private var scope: UsageStore.Scope = .all

    private var days: [String] { store.sortedDays(scope: scope) }

    var body: some View {
        #if os(iOS)
        Form {
            scopePickerSection
            summarySection
            ForEach(days, id: \.self) { day in
                Section {
                    daySectionContent(day)
                } header: {
                    Text(prettyDate(day))
                }
            }
            resetSection
        }
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                scopePickerCard
                summaryCard
                ForEach(days, id: \.self) { day in
                    dayCard(day)
                }
                if days.isEmpty {
                    emptyState
                }
                resetCard
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .topLeading)
        }
        #endif
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
        Section { scopePicker }
    }

    private var scopePickerCard: some View {
        cardShell {
            VStack(alignment: .leading, spacing: 8) {
                Text("查看范围")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                scopePicker
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
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("当日合计")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
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
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(provider)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
        .padding(.vertical, 4)
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
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.10), in: Capsule())
    }

    // MARK: - 总览

    @ViewBuilder
    private var summarySection: some View {
        Section { summaryRow }
    }

    private var summaryRow: some View {
        let total = store.grandTotal(scope: scope)
        let devices = store.deviceCount
        let isThisDeviceOnly = (scope == .thisDevice)
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(isThisDeviceOnly ? "本机累计" : "全部累计")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 6) {
                    Text("\(total.callCount) 次调用 · \(days.count) 天")
                    if !isThisDeviceOnly, devices > 1 {
                        Text("· \(devices) 台设备")
                            .foregroundStyle(Color.accentColor)
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
        .padding(.vertical, 4)
    }

    private var summaryCard: some View {
        cardShell { summaryRow }
    }

    private func dayCard(_ day: String) -> some View {
        cardShell {
            VStack(alignment: .leading, spacing: 8) {
                Text(prettyDate(day))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Divider()
                daySectionContent(day)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("还没有用量记录")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("发送一条消息后,模型的 token 用量会自动记录到这里。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
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
        cardShell {
            HStack {
                Text("管理")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清空所有用量记录", role: .destructive) {
                    confirmReset = true
                }
                .buttonStyle(.bordered)
            }
        }
        .confirmationDialog("确定要清空全部 token 用量记录?", isPresented: $confirmReset) {
            Button("清空", role: .destructive) { store.reset() }
            Button("取消", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func cardShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                Color.platformControlBackground.opacity(0.55),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            }
    }

    // MARK: - utils

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
