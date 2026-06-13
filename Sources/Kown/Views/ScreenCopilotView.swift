#if os(macOS)
import SwiftUI
import AppKit

/// 实时屏幕副驾(macOS 专属)。
///
/// 显式开启「看屏幕」后,节流截屏 + 本地 OCR 把屏幕文字喂进滚动缓冲;用户随口问
/// 「刚那页讲了啥 / 总结我刚读的这段」,基于缓冲即时作答。
///
/// 隐私优先的 UI 体现:醒目的红点「正在看屏幕」状态、随时可停、可清空缓冲、文案反复强调本机不上传。
struct ScreenCopilotView: View {
    @Bindable var viewModel: AppViewModel
    @ObservedObject private var copilot = ScreenCopilotService.shared

    @State private var question = ""
    @State private var answer = ""
    @State private var isAnswering = false
    @State private var errorMessage: String?
    /// 每秒 tick,驱动「N 秒前更新」相对时间刷新(不改 service 状态)。
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let tint = Color(red: 0.34, green: 0.42, blue: 0.92)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            controlBar
            bufferCard
            askCard
        }
        .onReceive(ticker) { now = $0 }
        .alert("出错了", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onChange(of: copilot.lastError) { _, new in
            if let new, !new.isEmpty { errorMessage = new }
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("实时屏幕副驾", systemImage: "eye.fill")
                .font(.title3.weight(.bold))
                .foregroundStyle(tint)
            Text("开启后每隔几秒截一次屏并在本机做文字识别,把你屏幕上看到的内容收进一个滚动缓冲。然后你可以随口问「刚那页讲了啥」「总结我刚读的这段」。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Label("全程本机处理:截图与识别都在你的 Mac 上完成,截图不会上传、缓冲也不落盘。", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !ScreenCaptureService.hasScreenRecordingPermission() {
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
                Text("需要「屏幕录制」权限才能读取屏幕内容。开启时系统会弹授权;授权后重开「看屏幕」即可。")
                    .font(.caption)
                if let url = ScreenCaptureService.screenRecordingSettingsURL {
                    Button("打开系统设置 › 屏幕录制") { NSWorkspace.shared.open(url) }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.link)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 控制条

    private var controlBar: some View {
        HStack(spacing: 14) {
            Button {
                copilot.isWatching ? copilot.stop() : copilot.start()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: copilot.isWatching ? "stop.circle.fill" : "eye.circle.fill")
                        .font(.system(size: 18))
                    Text(copilot.isWatching ? "停止看屏" : "开始看屏")
                        .font(.callout.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background((copilot.isWatching ? Color.red : tint).opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(copilot.isWatching ? Color.red : tint)
            }
            .buttonStyle(.plain)

            watchingIndicator

            VStack(alignment: .leading, spacing: 4) {
                Text("刷新间隔")
                    .font(.caption2).foregroundStyle(.secondary)
                Picker("", selection: $copilot.intervalSeconds) {
                    Text("2s").tag(2.0)
                    Text("3s").tag(3.0)
                    Text("4s").tag(4.0)
                    Text("5s").tag(5.0)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 醒目的「正在看屏幕」状态(隐私:用户必须一眼看到它在看屏)。
    private var watchingIndicator: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(copilot.isWatching ? Color.red : Color.secondary.opacity(0.4))
                .frame(width: 9, height: 9)
                .overlay {
                    if copilot.isWatching {
                        Circle().stroke(Color.red.opacity(0.4), lineWidth: 4).scaleEffect(1.6)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(copilot.isWatching ? "正在看屏幕" : "未在看屏")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(copilot.isWatching ? Color.red : .secondary)
                Text(captureStatusText)
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background((copilot.isWatching ? Color.red : Color.secondary).opacity(0.10),
                    in: Capsule(style: .continuous))
    }

    private var captureStatusText: String {
        guard copilot.frameCount > 0 else { return "尚未捕获" }
        if let last = copilot.lastCaptureAt {
            let secs = max(0, Int(now.timeIntervalSince(last)))
            return "\(copilot.frameCount) 帧 · \(secs)s 前"
        }
        return "\(copilot.frameCount) 帧"
    }

    // MARK: - 滚动缓冲

    private var bufferCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("屏幕滚动缓冲").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                if !copilot.buffer.isEmpty {
                    Button("清空") { copilot.clearBuffer() }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    if copilot.buffer.isEmpty {
                        Text(copilot.isWatching ? "正在读取屏幕…" : "点「开始看屏」后,屏幕上的文字会出现在这里。")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                    } else {
                        Text(copilot.buffer)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                        Color.clear.frame(height: 1).id(bufferAnchor)
                    }
                }
                .frame(minHeight: 140, maxHeight: 240)
                .onChange(of: copilot.buffer) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(bufferAnchor, anchor: .bottom)
                    }
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private let bufferAnchor = "screen-copilot-buffer-bottom"

    // MARK: - 提问

    private var askCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("基于屏幕内容提问").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("例如:总结我刚读的这段 / 刚那页讲了啥", text: $question, onCommit: ask)
                    .textFieldStyle(.roundedBorder)
                Button(action: ask) {
                    if isAnswering { ProgressView().controlSize(.small) }
                    else { Image(systemName: "paperplane.fill") }
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .disabled(isAnswering || copilot.buffer.isEmpty)
            }
            quickChips
            if !answer.isEmpty {
                ScrollView {
                    Text(answer)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .padding(12)
                .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var quickChips: some View {
        HStack(spacing: 8) {
            chip("总结我刚读的这段")
            chip("刚那页讲了啥")
            chip("提取要点")
        }
    }

    private func chip(_ text: String) -> some View {
        Button {
            question = text
            ask()
        } label: {
            Text(text)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(tint.opacity(0.10), in: Capsule(style: .continuous))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .disabled(isAnswering || copilot.buffer.isEmpty)
    }

    // MARK: - 动作

    private func ask() {
        let q = question
        guard !isAnswering, !copilot.buffer.isEmpty else { return }
        isAnswering = true
        answer = ""
        Task {
            let err = await viewModel.answerFromScreen(question: q) { delta in
                answer += delta
            }
            if let err { errorMessage = err }
            isAnswering = false
        }
    }
}
#endif
