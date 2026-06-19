import SwiftUI
import UniformTypeIdentifiers

/// 录音 / 会议转写 → AI 纪要 → 写入提醒。作为 sheet 弹出。
///
/// 流程:
///  1. 实时录音(复用 `SpeechRecognizer.shared`,把 partial 累积成整段)或导入音频文件
///     (`AudioTranscriptionService`,本地 `SFSpeechRecognizer`)。
///  2. 得到转写文字后,`MeetingNotesSummarizer` 调模型提炼出摘要 / 决议 / 行动项。
///  3. 勾选行动项,一键写进系统「提醒事项」(可选同时写日历),走 `EventKitService`。
struct MeetingNotesView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    // 转写
    @StateObject private var recognizer = SpeechRecognizer.shared
    @State private var transcript: String = ""
    @State private var isTranscribingFile = false
    @State private var showImporter = false

    // 纪要
    @State private var notes: MeetingNotes?
    @State private var isSummarizing = false

    // 行动项写入
    @State private var selectedActionIDs: Set<UUID> = []
    @State private var alsoCalendar = false
    @State private var isWriting = false
    @State private var writeResult: String?

    @State private var errorMessage: String?

    #if os(macOS)
    // 会议实时双轨捕获(macOS 专属)入口。
    @State private var showLiveMeeting = false
    #endif

    private let tint = Color(red: 0.85, green: 0.42, blue: 0.18)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    heroCard
                    #if os(macOS)
                    liveMeetingEntryCard
                    #endif
                    captureCard
                    transcriptCard
                    if let notes { notesSection(notes) }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .navigationTitle("会议纪要")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        if recognizer.isRecording { recognizer.stop() }
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 620)
        .sheet(isPresented: $showLiveMeeting) {
            NavigationStack {
                ScrollView {
                    MeetingCaptureView(viewModel: viewModel)
                        .padding(.horizontal, 20).padding(.vertical, 18)
                }
                .scrollIndicators(.hidden)
                .navigationTitle("会议实时捕获")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") {
                            if MeetingCaptureService.shared.isCapturing {
                                Task { await MeetingCaptureService.shared.stop() }
                            }
                            showLiveMeeting = false
                        }
                    }
                }
            }
            .frame(minWidth: 600, minHeight: 640)
        }
        #endif
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: audioTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                transcribeFile(url)
            }
        }
        .alert("出错了", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: recognizer.lastError) { _, new in
            if let new, !new.isEmpty { errorMessage = new }
        }
    }

    // MARK: - 头部

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("录音 / 会议转写", systemImage: "waveform.badge.mic")
                .font(.title3.weight(.bold))
                .foregroundStyle(tint)
            Text("实时录音或导入音频文件,本地转写成文字,再让 AI 提炼成摘要、关键决议和行动项,一键写进提醒。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    #if os(macOS)
    // MARK: - 会议实时双轨捕获入口(macOS 专属)

    private var liveMeetingEntryCard: some View {
        Button {
            showLiveMeeting = true
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.2.wave.2.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text("开会时直接用 · 双轨实时捕获")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.primary)
                    Text("Zoom / 腾讯会议开着时,同时录对方声音(系统声音)和你的麦克风,实时双色字幕,停止后出带说话人维度的纪要。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Image(systemName: "chevron.right").foregroundStyle(.secondary).font(.caption)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(tint.opacity(0.25), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    #endif

    // MARK: - 采集(录音 / 导入)

    private var captureCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1 · 获取转写")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    toggleRecording()
                } label: {
                    Label(
                        recognizer.isRecording ? "停止录音" : "开始录音",
                        systemImage: recognizer.isRecording ? "stop.circle.fill" : "mic.circle.fill"
                    )
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        (recognizer.isRecording ? Color.red : tint).opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .foregroundStyle(recognizer.isRecording ? Color.red : tint)
                }
                .buttonStyle(.plain)
                .disabled(isTranscribingFile)

                Button {
                    showImporter = true
                } label: {
                    Label("导入音频", systemImage: "square.and.arrow.down")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.secondary.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .disabled(recognizer.isRecording || isTranscribingFile)
            }

            if recognizer.isRecording {
                Label("正在录音,实时转写中…", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if isTranscribingFile {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在转写音频文件…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - 转写文字 + 生成纪要

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("转写文字")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !transcript.isEmpty {
                    Button("清空") {
                        transcript = ""
                        notes = nil
                        selectedActionIDs = []
                        writeResult = nil
                    }
                    .font(.caption)
                }
            }

            TextEditor(text: $transcript)
                .font(.callout)
                .frame(minHeight: 120, maxHeight: 220)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                #if os(iOS)
                .autocorrectionDisabled()
                #endif

            Button {
                generateNotes()
            } label: {
                HStack {
                    if isSummarizing { ProgressView().controlSize(.small) }
                    Text(isSummarizing ? "正在生成纪要…" : "2 · 生成 AI 纪要")
                        .font(.callout.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(canSummarize ? tint : Color.secondary.opacity(0.25),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(canSummarize ? Color.white : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSummarize)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var canSummarize: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSummarizing && !recognizer.isRecording
    }

    // MARK: - 纪要展示

    private func notesSection(_ notes: MeetingNotes) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if !notes.summary.isEmpty {
                infoBlock(title: "摘要", icon: "text.alignleft") {
                    Text(notes.summary)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if !notes.decisions.isEmpty {
                infoBlock(title: "关键决议", icon: "checkmark.seal") {
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
                actionItemsBlock(notes.actionItems)
            }
        }
    }

    private func actionItemsBlock(_ items: [MeetingNotes.ActionItem]) -> some View {
        infoBlock(title: "行动项", icon: "checklist") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(items) { item in
                    actionRow(item)
                }

                Divider().padding(.vertical, 2)

                Toggle("同时写入日历", isOn: $alsoCalendar)
                    .font(.caption)
                    .tint(tint)

                Button {
                    writeSelectedActions(items)
                } label: {
                    HStack {
                        if isWriting { ProgressView().controlSize(.small) }
                        Text(isWriting ? "正在写入…" : "3 · 写入提醒(\(selectedActionIDs.count))")
                            .font(.callout.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(selectedActionIDs.isEmpty || isWriting ? Color.secondary.opacity(0.25) : tint,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(selectedActionIDs.isEmpty || isWriting ? Color.secondary : Color.white)
                }
                .buttonStyle(.plain)
                .disabled(selectedActionIDs.isEmpty || isWriting)

                if let writeResult {
                    Text(writeResult)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .onAppear {
            // 默认全选行动项,省一步。
            if selectedActionIDs.isEmpty {
                selectedActionIDs = Set(items.map(\.id))
            }
        }
    }

    private func actionRow(_ item: MeetingNotes.ActionItem) -> some View {
        let isOn = selectedActionIDs.contains(item.id)
        return Button {
            if isOn { selectedActionIDs.remove(item.id) } else { selectedActionIDs.insert(item.id) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? tint : .secondary)
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.task)
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 10) {
                        if let owner = item.owner {
                            Label(owner, systemImage: "person")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if let due = item.dueText {
                            Label(due, systemImage: "calendar")
                                .font(.caption2)
                                .foregroundStyle(item.dueDate != nil ? Color.secondary : Color.orange)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func infoBlock<Content: View>(
        title: String, icon: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - 录音(复用 SpeechRecognizer,把 partial 累积成整段)
    //
    // SpeechRecognizer 的 partial 回调给的是「本次识别 task 的完整文本」(从头累积),
    // 不是增量。所以记录开录前已有的文字 `recordingBase`,每次 partial 拼成 base + partial。

    @State private var recordingBase = ""

    private func toggleRecording() {
        if recognizer.isRecording {
            recognizer.stop()
            return
        }
        // 开录:以现有文字为基底,后面追加这一段。
        recordingBase = transcript.isEmpty ? "" : transcript + "\n"
        recognizer.start { partial in
            transcript = recordingBase + partial
        }
    }

    // MARK: - 文件转写

    private func transcribeFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        isTranscribingFile = true
        let base = transcript.isEmpty ? "" : transcript + "\n"
        Task {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try await AudioTranscriptionService.transcribe(url: url) { partial in
                    Task { @MainActor in
                        transcript = base + partial
                    }
                }
                await MainActor.run {
                    transcript = base + text
                    isTranscribingFile = false
                }
            } catch {
                await MainActor.run {
                    isTranscribingFile = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - 生成纪要

    private func generateNotes() {
        guard let provider = pickProvider() else {
            errorMessage = MeetingNotesSummarizer.SummarizeError.noProvider.localizedDescription
            return
        }
        isSummarizing = true
        writeResult = nil
        selectedActionIDs = []
        let text = transcript
        Task {
            do {
                let result = try await MeetingNotesSummarizer.summarize(transcript: text, provider: provider)
                await MainActor.run {
                    notes = result
                    isSummarizing = false
                }
            } catch {
                await MainActor.run {
                    isSummarizing = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// 选 provider:裁判优先,否则第一家 enabled 非 CLI(与 summarizer / extractor 一致)。
    private func pickProvider() -> ProviderConfig? {
        if let chair = viewModel.chairProvider, !chair.kind.isCLI { return chair }
        return viewModel.providers.first { $0.enabled && !$0.kind.isCLI }
    }

    // MARK: - 写入提醒 / 日历

    private func writeSelectedActions(_ items: [MeetingNotes.ActionItem]) {
        let chosen = items.filter { selectedActionIDs.contains($0.id) }
        guard !chosen.isEmpty else { return }
        isWriting = true
        writeResult = nil
        let writeCalendar = alsoCalendar
        let noteContext = notes?.summary
        Task {
            #if canImport(EventKit)
            var reminderCount = 0
            var eventCount = 0
            var firstError: String?
            for item in chosen {
                do {
                    _ = try await EventKitService.shared.createReminder(
                        title: item.reminderTitle,
                        notes: noteContext,
                        due: item.dueDate
                    )
                    reminderCount += 1
                } catch {
                    if firstError == nil { firstError = error.localizedDescription }
                }
                if writeCalendar, let due = item.dueDate {
                    do {
                        _ = try await EventKitService.shared.createEvent(
                            title: item.reminderTitle,
                            notes: noteContext,
                            start: due,
                            end: nil,
                            location: nil
                        )
                        eventCount += 1
                    } catch {
                        if firstError == nil { firstError = error.localizedDescription }
                    }
                }
            }
            await MainActor.run {
                isWriting = false
                if reminderCount == 0, let firstError {
                    errorMessage = firstError
                } else {
                    var msg = "已写入 \(reminderCount) 条提醒"
                    if writeCalendar { msg += "、\(eventCount) 个日历事件" }
                    writeResult = msg + "。"
                }
            }
            #else
            await MainActor.run {
                isWriting = false
                errorMessage = "当前平台不支持写入提醒事项。"
            }
            #endif
        }
    }

    // MARK: - 支持的音频类型

    private var audioTypes: [UTType] {
        var types: [UTType] = [.audio, .mpeg4Audio, .wav, .mp3, .aiff]
        if let m4a = UTType(filenameExtension: "m4a") { types.append(m4a) }
        if let caf = UTType(filenameExtension: "caf") { types.append(caf) }
        return types
    }
}
