import SwiftUI

/// 语音随手记自动归档(跨平台)。
///
/// 按住开始 → 实时转写(复用 `SpeechRecognizer.shared`)→ 停止后一键保存:
/// LLM 自动起标题 + 按主题/项目打标 → 存进知识库「语音随手记」资料夹,之后可被语义召回。
///
/// CPU / 并发:转写走 `SpeechRecognizer`(其自身在后台线程回调、主线程发布);
/// 打标 + 入库走 `AppViewModel.saveVoiceJournal`(后台流式 + actor 预索引),不阻塞 UI。
struct VoiceJournalView: View {
    @Bindable var viewModel: AppViewModel
    @StateObject private var recognizer = SpeechRecognizer.shared

    @State private var transcript = ""
    @State private var recordingBase = ""
    @State private var isSaving = false
    @State private var lastResult: AppViewModel.VoiceJournalSaveResult?
    @State private var errorMessage: String?

    private let tint = Color(red: 0.30, green: 0.50, blue: 0.90)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            recordCard
            transcriptCard
            if let result = lastResult { savedCard(result) }
            recentCard
        }
        .alert("出错了", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onChange(of: recognizer.lastError) { _, new in
            if let new, !new.isEmpty { errorMessage = new }
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("语音随手记", systemImage: "mic.badge.plus")
                .font(.title3.weight(.bold))
                .foregroundStyle(tint)
            Text("随口说一段,实时转成文字;保存时自动起标题、按主题/项目打标,存进知识库「\(AppViewModel.voiceJournalFolderName)」资料夹,以后能被语义召回。")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !viewModel.voiceJournalCanTag {
                Label("当前没有可用模型,仍可保存随手记,只是不会自动打标。", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - 录音控制

    private var recordCard: some View {
        HStack(spacing: 14) {
            Button(action: toggleRecording) {
                HStack(spacing: 8) {
                    Image(systemName: recognizer.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 18))
                    Text(recognizer.isRecording ? "停止录音" : "开始录音")
                        .font(.callout.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background((recognizer.isRecording ? Color.red : tint).opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(recognizer.isRecording ? Color.red : tint)
            }
            .buttonStyle(.plain)
            .disabled(isSaving)

            if recognizer.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text("正在听写…").font(.caption).foregroundStyle(.red)
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - 转写

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("转写").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                if !transcript.isEmpty && !recognizer.isRecording {
                    Button("清空") { transcript = ""; recordingBase = "" }
                        .font(.caption.weight(.semibold)).buttonStyle(.borderless)
                }
            }
            #if os(macOS)
            TextEditor(text: $transcript)
                .font(.callout)
                .frame(minHeight: 120, maxHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.platformControlBackground.opacity(0.5),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            #else
            TextEditor(text: $transcript)
                .font(.callout)
                .frame(minHeight: 120, maxHeight: 220)
                .padding(6)
                .background(Color.platformControlBackground.opacity(0.5),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            #endif

            Button(action: save) {
                HStack(spacing: 8) {
                    if isSaving { ProgressView().controlSize(.small) }
                    Image(systemName: "tray.and.arrow.down.fill")
                    Text(isSaving ? "正在打标并归档…" : "保存并自动归档")
                        .font(.callout.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .disabled(isSaving || recognizer.isRecording || canSaveDisabled)
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var canSaveDisabled: Bool {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 已保存结果

    private func savedCard(_ result: AppViewModel.VoiceJournalSaveResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("已归档", systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.bold)).foregroundStyle(.green)
            Text(result.title).font(.callout.weight(.medium))
            if !result.tags.isEmpty {
                WrappingHStack(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(result.tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(tint.opacity(0.12), in: Capsule(style: .continuous))
                            .foregroundStyle(tint)
                    }
                }
            }
            Text(result.taggedByLLM
                 ? "已存进「\(AppViewModel.voiceJournalFolderName)」资料夹,可在知识库里被语义召回。"
                 : "已存进「\(AppViewModel.voiceJournalFolderName)」资料夹(未自动打标)。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - 最近随手记

    @ViewBuilder
    private var recentCard: some View {
        if let folder = viewModel.voiceJournalFolder, !folder.docs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("最近的随手记").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(folder.docs.count) 条").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(folder.docs.suffix(5).reversed()) { doc in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "doc.text").foregroundStyle(tint).font(.caption)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(doc.name).font(.callout.weight(.medium)).lineLimit(1)
                            Text(doc.text).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
            .padding(14)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: - 动作

    private func toggleRecording() {
        if recognizer.isRecording {
            recognizer.stop()
            return
        }
        #if os(macOS)
        // 与会议捕获互斥(共用麦克风 + 识别)。
        if MeetingCaptureService.shared.isCapturing {
            errorMessage = "会议捕获正在进行中,请先停止再录随手记(两者都要用麦克风)。"
            return
        }
        #endif
        recordingBase = transcript.isEmpty ? "" : transcript + "\n"
        recognizer.start { partial in
            transcript = recordingBase + partial
        }
    }

    private func save() {
        guard !canSaveDisabled else { return }
        let text = transcript
        isSaving = true
        Task {
            let result = await viewModel.saveVoiceJournal(transcript: text)
            isSaving = false
            if let err = result.error {
                errorMessage = err
            } else {
                lastResult = result
                transcript = ""
                recordingBase = ""
            }
        }
    }
}
