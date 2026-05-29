import SwiftUI

/// Settings → 性能 tab。
///
/// 目前只放一个选项:**流式响应刷新间隔**。
/// 默认 50ms ≈ 20Hz 已经很丝滑;低性能 / 老 Intel Mac 可调到 100 / 200 / 500ms,
/// 字会一段一段跳出来但 CPU 占用进一步下降。
struct PerformanceSettingsView: View {
    @AppStorage(ResponseState.flushIntervalKey) private var intervalRaw: Int = ResponseState.defaultFlushIntervalMs

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
        Form {
            Section {
                picker
            } header: {
                Text("流式刷新间隔")
            } footer: {
                Text(footerText)
            }
        }
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("流式刷新间隔")
                            .font(.headline)
                        picker
                        Text(footerText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .topLeading)
        }
        #endif
    }

    private var picker: some View {
        Picker("刷新间隔", selection: binding) {
            ForEach(ResponseState.allowedFlushIntervalsMs, id: \.self) { ms in
                Text("\(ms) ms").tag(ms)
            }
        }
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

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
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
}
