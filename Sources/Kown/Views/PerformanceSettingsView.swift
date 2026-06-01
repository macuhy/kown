import SwiftUI

/// Settings → 性能 tab。
///
/// 目前只放一个选项:**流式响应刷新间隔**。
/// 默认 50ms ≈ 20Hz 已经很丝滑;低性能 / 老 Intel Mac 可调到 100 / 200 / 500ms,
/// 字会一段一段跳出来但 CPU 占用进一步下降。
struct PerformanceSettingsView: View {
    @AppStorage(ResponseState.flushIntervalKey) private var intervalRaw: Int = ResponseState.defaultFlushIntervalMs
    /// 与 AppViewModel.autoFailoverEnabled 同一 UserDefaults key,直接 AppStorage 绑定保持同步。
    @AppStorage("kown.autoFailover.v1") private var autoFailover: Bool = false
    /// 与 AppViewModel.councilVotingEnabled 同一 key。
    @AppStorage("kown.councilVoting.v1") private var councilVoting: Bool = false
    /// 与 AppViewModel.autoRouteEnabled 同一 key。
    @AppStorage("kown.autoRoute.v1") private var autoRoute: Bool = false

    private let tint = Color(red: 0.88, green: 0.35, blue: 0.22)
    private let secondaryTint = Color(red: 0.91, green: 0.55, blue: 0.20)

    /// AppStorage 读出来的 raw 值如果不在白名单里(比如老版本残留 0),fall back 到默认
    private var current: Int {
        ResponseState.allowedFlushIntervalsMs.contains(intervalRaw)
            ? intervalRaw
            : ResponseState.defaultFlushIntervalMs
    }

    private var binding: Binding<Int> {
        Binding(get: { current }, set: { intervalRaw = $0 })
    }

    var body: some View {
        #if os(iOS)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                heroCard
                settingCard
                autoFailoverCard
                councilVotingCard
                autoRouteCard
                guideCard
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
                settingCard
                autoFailoverCard
                councilVotingCard
                autoRouteCard
                guideCard
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .topLeading)
        }
        #endif
    }

    // MARK: - 自动容错

    private var autoFailoverCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $autoFailover) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("自动容错切换")
                        .font(.body.weight(.semibold))
                    Text("某个模型回答失败时,自动换另一家已启用的模型重试一次(纯文本)。回答会标注已切换到哪家。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(tint)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.16), lineWidth: 1)
        }
    }

    // MARK: - Council 投票

    private var councilVotingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $councilVoting) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Council 投票打分")
                        .font(.body.weight(.semibold))
                    Text("Council 模式里,主席综合后再额外跑一次评审,对各家答案按准确/完整/可执行/清晰四维打分并排名。会多一次模型调用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(secondaryTint)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(secondaryTint.opacity(0.16), lineWidth: 1)
        }
    }

    // MARK: - 自动路由

    private var autoRouteCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $autoRoute) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("按难度自动选模型(Direct,实验)")
                        .font(.body.weight(.semibold))
                    Text("Direct 模式下,按问题难度在当前模型所属厂商里自动切换档位:简单问题走便宜模型,复杂问题走旗舰。卡片会显示实际用的型号。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(secondaryTint)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(secondaryTint.opacity(0.16), lineWidth: 1)
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private var heroCard: some View {
        #if os(iOS)
        mobileHeroCard
        #else
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                iconTile("speedometer", tint: tint, secondary: secondaryTint)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text("性能")
                            .font(.system(.title2, design: .rounded).weight(.bold))
                        statusBadge(performanceBadgeText, icon: "gauge.with.dots.needle.33percent", color: performanceColor)
                    }
                    Text("调整流式响应的刷新节奏。间隔越短越丝滑,间隔越长越省电、CPU 压力越低。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(current) ms")
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .monospacedDigit()
                    Text(frequencyText(current))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                metricTile(title: "当前档位",
                           value: "\(current) ms",
                           detail: footerText,
                           icon: "timer",
                           color: performanceColor)
                metricTile(title: "默认值",
                           value: "\(ResponseState.defaultFlushIntervalMs) ms",
                           detail: "丝滑与省电的平衡点",
                           icon: "checkmark.seal.fill",
                           color: .green)
                metricTile(title: "刷新频率",
                           value: frequencyText(current),
                           detail: "约每秒 UI 刷新次数",
                           icon: "waveform.path.ecg",
                           color: secondaryTint)
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
        #endif
    }

    #if os(iOS)
    private var mobileHeroCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 10) {
                compactIconTile("speedometer", tint: tint, secondary: secondaryTint)

                VStack(alignment: .leading, spacing: 2) {
                    Text("性能")
                        .font(.headline.weight(.bold))
                        .lineLimit(1)
                    Text(performanceBadgeText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(current) ms")
                        .font(.title3.weight(.black))
                        .monospacedDigit()
                    Text(frequencyText(current))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Text("调整流式响应刷新节奏,控制观感和 CPU 压力。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            VStack(spacing: 7) {
                compactMetricRow(title: "当前档位",
                                 value: "\(current) ms",
                                 detail: footerText,
                                 icon: "timer",
                                 color: performanceColor)
                compactMetricRow(title: "默认值",
                                 value: "\(ResponseState.defaultFlushIntervalMs) ms",
                                 detail: "丝滑与省电的平衡点",
                                 icon: "checkmark.seal.fill",
                                 color: .green)
                compactMetricRow(title: "刷新频率",
                                 value: frequencyText(current),
                                 detail: "约每秒 UI 刷新次数",
                                 icon: "waveform.path.ecg",
                                 color: secondaryTint)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(heroBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(tint.opacity(0.20), lineWidth: 1)
        }
        .shadow(color: tint.opacity(0.06), radius: 12, x: 0, y: 7)
    }
    #endif

    private var settingCard: some View {
        card(tint: tint) {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("流式刷新间隔", subtitle: "即时生效,只改变 UI 刷新频率,不影响模型生成速度。", icon: "slider.horizontal.below.rectangle", color: tint)
                picker
                messageBanner(footerText, icon: "info.circle.fill", color: performanceColor)
            }
        }
    }

    private var guideCard: some View {
        card(tint: secondaryTint) {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("档位说明", subtitle: "从更丝滑到更省电,按机器性能和个人偏好选择。", icon: "list.bullet.rectangle.fill", color: secondaryTint)
                intervalGuide
            }
        }
    }

    private var intervalGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(ResponseState.allowedFlushIntervalsMs, id: \.self) { ms in
                HStack(spacing: 10) {
                    Text("\(ms) ms")
                        .font(.system(.callout, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .frame(width: 72, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(intervalTitle(ms))
                            .font(.callout.weight(.semibold))
                        Text(intervalDetail(ms))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if ms == current {
                        statusBadge("当前", icon: "checkmark", color: performanceColor)
                    }
                }
                .padding(11)
                .background((ms == current ? performanceColor : Color.primary).opacity(ms == current ? 0.10 : 0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder((ms == current ? performanceColor : Color.primary).opacity(ms == current ? 0.18 : 0.06), lineWidth: 1)
                }
            }
        }
    }

    private var picker: some View {
        Picker("刷新间隔", selection: binding) {
            ForEach(ResponseState.allowedFlushIntervalsMs, id: \.self) { ms in
                Text("\(ms) ms").tag(ms)
            }
        }
        #if os(iOS)
        .pickerStyle(.segmented)
        #endif
        #if os(macOS)
        .pickerStyle(.segmented)
        #endif
    }

    private var footerText: String {
        switch current {
        case 30:  return "30ms ≈ 33Hz — 最丝滑,CPU 占用最高。新机器、想看字一个个跳出来。"
        case 50:  return "50ms ≈ 20Hz — 默认,丝滑 & 省电的平衡点。"
        case 100: return "100ms = 10Hz — 字会成片出现,CPU 明显下降。一般电脑首选。"
        case 200: return "200ms = 5Hz — 节奏明显放缓,但 CPU 大幅下降。Intel Mac / 低配机器。"
        case 500: return "500ms = 2Hz — 极致省电,字会一大段一大段刷。"
        default:  return "默认 50ms。"
        }
    }

    // MARK: - Styling helpers

    #if os(iOS)
    private var mobileSettingsBackground: some View {
        ZStack {
            Color.platformWindowBackground
            RadialGradient(
                colors: [tint.opacity(0.13), Color.clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 420
            )
            RadialGradient(
                colors: [secondaryTint.opacity(0.10), Color.clear],
                center: .bottomTrailing,
                startRadius: 50,
                endRadius: 520
            )
        }
    }

    private var heroSection: some View {
        Section {
            heroCard
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
    }
    #endif

    private var performanceColor: Color {
        switch current {
        case 30: return tint
        case 50: return .green
        case 100: return secondaryTint
        case 200, 500: return .blue
        default: return .secondary
        }
    }

    private var performanceBadgeText: String {
        switch current {
        case 30: return "极致丝滑"
        case 50: return "默认平衡"
        case 100: return "省电"
        case 200, 500: return "低负载"
        default: return "默认"
        }
    }

    private var heroBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: heroCornerRadius, style: .continuous)
                .fill(.regularMaterial)
            RoundedRectangle(cornerRadius: heroCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.16), secondaryTint.opacity(0.10), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }

    private var heroCornerRadius: CGFloat {
        #if os(iOS)
        return 20
        #else
        return 28
        #endif
    }

    #if os(iOS)
    private func compactIconTile(_ symbol: String, tint: Color, secondary: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.95), secondary.opacity(0.78)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 42, height: 42)
    }
    #endif

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

    private func compactMetricRow(title: String, value: String, detail: String, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 25, height: 25)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(color.opacity(0.14), lineWidth: 1)
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

    private func messageBanner(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(color.opacity(0.18), lineWidth: 1)
            }
    }

    @ViewBuilder
    private func card<Content: View>(tint: Color, @ViewBuilder content: () -> Content) -> some View {
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

    private func frequencyText(_ ms: Int) -> String {
        guard ms > 0 else { return "默认" }
        let hz = 1000.0 / Double(ms)
        if hz >= 10 {
            return "≈ \(Int(round(hz)))Hz"
        }
        return String(format: "≈ %.1fHz", hz)
    }

    private func intervalTitle(_ ms: Int) -> String {
        switch ms {
        case 30: return "最丝滑"
        case 50: return "默认平衡"
        case 100: return "一般电脑首选"
        case 200: return "低配 / Intel 友好"
        case 500: return "极致省电"
        default: return "自定义"
        }
    }

    private func intervalDetail(_ ms: Int) -> String {
        switch ms {
        case 30: return "字更接近逐个出现,CPU 占用最高。"
        case 50: return "推荐默认值,兼顾观感和能耗。"
        case 100: return "文字成片刷新,显著降低 UI 更新频率。"
        case 200: return "刷新节奏明显放慢,适合老机器。"
        case 500: return "一大段一大段刷出,最大限度省电。"
        default: return "默认 50ms。"
        }
    }
}
