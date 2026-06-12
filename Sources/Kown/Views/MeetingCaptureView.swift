#if os(macOS)
import SwiftUI

/// 会议实时双轨捕获(macOS 专属)。
///
/// 「开会时直接用」:Zoom / 腾讯会议在 Mac 上开着,这里同时捕获**系统声音(对方)** +
/// **麦克风(我)**,双轨实时转写成双色字幕;停止后一键生成带说话人维度的纪要。
///
/// - 实时字幕:渲染 `MeetingCaptureService.liveUtterances`(已按时间合并好的时间线),
///   用 `LazyVStack` + 稳定 `id` 增量追加,绝不整页重渲染(CPU 卡死前科)。
/// - 纪要:停止后把 `renderedTranscript()` 交给 `MeetingNotesSummarizer`(prompt 带说话人维度)。
struct MeetingCaptureView: View {
    @Bindable var viewModel: AppViewModel
    @ObservedObject private var capture = MeetingCaptureService.shared

    @State private var isStarting = false
    @State private var notes: MeetingNotes?
    @State private var isSummarizing = false
    @State private var errorMessage: String?
    @State private var showPermissionHint = false

    private let tint = Color(red: 0.85, green: 0.42, blue: 0.18)
    private let meColor = Color(red: 0.20, green: 0.55, blue: 0.90)   // 我:蓝
    private let themColor = Color(red: 0.85, green: 0.42, blue: 0.18) // 对方:橙

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            controlBar
            liveSubtitles
            if let notes { MeetingNotesResultView(notes: notes, viewModel: viewModel, tint: tint) }
        }
        .alert("出错了", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onChange(of: capture.lastError) { _, new in
            if let new, !new.isEmpty { errorMessage = new }
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("会议实时捕获", systemImage: "person.2.wave.2.fill")
                .font(.title3.weight(.bold))
                .foregroundStyle(tint)
            Text("开着 Zoom / 腾讯会议时,同时捕获对方声音(系统声音)和你的麦克风,双轨实时转写。停止后生成带说话人维度的纪要。")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !SystemAudioCaptureService.hasScreenRecordingPermission() {
                permissionBanner
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var permissionBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("要捕获对方声音,需开启「屏幕录制」权限(用于读取系统声音)。")
                    .font(.caption)
                if let url = SystemAudioCaptureService.screenRecordingSettingsURL {
                    Button("打开系统设置 › 屏幕录制") {
                        NSWorkspace.shared.open(url)
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.link)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 控制条(开始 / 停止 + 计时)

    private var controlBar: some View {
        HStack(spacing: 14) {
            Button {
                capture.isCapturing ? stopCapture() : startCapture()
            } label: {
                HStack(spacing: 8) {
                    if isStarting { ProgressView().controlSize(.small) }
                    Image(systemName: capture.isCapturing ? "stop.circle.fill" : "record.circle.fill")
                        .font(.system(size: 18))
                    Text(capture.isCapturing ? "停止会议" : (isStarting ? "正在开始…" : "开始会议"))
                        .font(.callout.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background((capture.isCapturing ? Color.red : tint).opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(capture.isCapturing ? Color.red : tint)
            }
            .buttonStyle(.plain)
            .disabled(isStarting || isSummarizing)

            VStack(alignment: .trailing, spacing: 2) {
                Text(timeLabel(capture.elapsed))
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .foregroundStyle(capture.isCapturing ? .primary : .secondary)
                HStack(spacing: 6) {
                    trackDot("我", on: capture.isCapturing, color: meColor)
                    trackDot("对方", on: capture.isCapturing && capture.systemTrackActive, color: themColor)
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func trackDot(_ label: String, on: Bool, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(on ? color : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
            Text(label).font(.caption2).foregroundStyle(on ? color : .secondary)
        }
    }

    // MARK: - 实时双色字幕

    private var liveSubtitles: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("实时字幕").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                if !capture.liveUtterances.isEmpty && !capture.isCapturing {
                    Button("生成纪要") { generateNotes() }
                        .font(.caption.weight(.semibold))
                        .disabled(isSummarizing)
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if capture.liveUtterances.isEmpty {
                            Text(capture.isCapturing ? "正在聆听…" : "点「开始会议」开始捕获。")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 24)
                        }
                        ForEach(capture.liveUtterances) { u in
                            subtitleRow(u).id(u.id)
                        }
                        Color.clear.frame(height: 1).id(scrollAnchor)
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 200, maxHeight: 320)
                .onChange(of: capture.liveUtterances.count) { _, _ in
                    // 只在条数变化时滚到底(增量追加,不整页重排)。
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(scrollAnchor, anchor: .bottom)
                    }
                }
            }

            if isSummarizing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在生成会议纪要…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private let scrollAnchor = "meeting-subtitles-bottom"

    private func subtitleRow(_ u: MeetingUtterance) -> some View {
        let isMe = u.speaker == .me
        let color = isMe ? meColor : themColor
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(u.speaker.rawValue)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(color.opacity(0.18), in: Capsule())
                    .foregroundStyle(color)
                Text(MeetingTranscriptMerger.timestampLabel(u.start))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(u.text)
                .font(.callout)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - 动作

    private func startCapture() {
        notes = nil
        isStarting = true
        Task {
            do {
                try await capture.start()
            } catch {
                errorMessage = error.localizedDescription
            }
            isStarting = false
        }
    }

    private func stopCapture() {
        Task { await capture.stop() }
    }

    private func generateNotes() {
        guard let provider = pickProvider() else {
            errorMessage = MeetingNotesSummarizer.SummarizeError.noProvider.localizedDescription
            return
        }
        let transcript = capture.renderedTranscript()
        isSummarizing = true
        Task {
            do {
                let result = try await MeetingNotesSummarizer.summarizeMeeting(
                    transcript: transcript, provider: provider
                )
                notes = result
            } catch {
                errorMessage = error.localizedDescription
            }
            isSummarizing = false
        }
    }

    private func pickProvider() -> ProviderConfig? {
        if let chair = viewModel.chairProvider, !chair.kind.isCLI { return chair }
        return viewModel.providers.first { $0.enabled && !$0.kind.isCLI }
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        let total = (seconds.isFinite && seconds > 0) ? Int(seconds.rounded(.down)) : 0
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

/// 会议纪要展示(摘要 / 决议 / 行动项),供 `MeetingCaptureView` 停止后展示。
/// 复用 `MeetingNotes` 结构;此处只读展示,写入提醒沿用 `MeetingNotesView` 的能力(本视图不重复实现)。
private struct MeetingNotesResultView: View {
    let notes: MeetingNotes
    @Bindable var viewModel: AppViewModel
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !notes.summary.isEmpty {
                block("摘要", "text.alignleft") {
                    Text(notes.summary).font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !notes.decisions.isEmpty {
                block("关键决议", "checkmark.seal") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(notes.decisions.enumerated()), id: \.offset) { _, d in
                            HStack(alignment: .top, spacing: 8) {
                                Text("•").foregroundStyle(tint)
                                Text(d).font(.callout)
                            }
                        }
                    }
                }
            }
            if !notes.actionItems.isEmpty {
                block("行动项", "checklist") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(notes.actionItems) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "circle").foregroundStyle(.secondary).font(.callout)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.task).font(.callout.weight(.medium))
                                    HStack(spacing: 10) {
                                        if let owner = item.owner {
                                            Label(owner, systemImage: "person").font(.caption2).foregroundStyle(.secondary)
                                        }
                                        if let due = item.dueText {
                                            Label(due, systemImage: "calendar").font(.caption2)
                                                .foregroundStyle(item.dueDate != nil ? Color.secondary : Color.orange)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func block<Content: View>(_ title: String, _ icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.subheadline.weight(.bold)).foregroundStyle(tint)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
#endif
