import SwiftUI

/// 朗读(TTS)设置:选引擎 / 音色 / 语速,Azure key+region,试听。
struct TTSSettingsView: View {
    @State private var engine: TTSEngineKind = TTSConfig.engine
    @State private var voice: String = TTSConfig.voice
    @State private var rate: Double = Double(TTSConfig.ratePercent)
    @State private var azureRegion: String = TTSConfig.azureRegion
    @State private var azureKey: String = ""
    @State private var keySaved: Bool = false

    @ObservedObject private var speech = SpeechService.shared

    private let sampleText = "你好,我是 Kown 的朗读语音。这是一段试听示例,用来听听音色和语速是否合适。"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                enginePicker
                if engine != .system {
                    voicePicker
                    rateSlider
                }
                if engine == .azure {
                    azureSection
                }
                previewSection
                noteSection
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .onAppear { keySaved = TTSConfig.azureKey?.isEmpty == false }
    }

    private var enginePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("朗读引擎", icon: "waveform")
            ForEach(TTSEngineKind.allCases) { kind in
                Button {
                    engine = kind
                    TTSConfig.engine = kind
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: engine == kind ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(engine == kind ? Color.accentColor : .secondary)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(kind.displayName)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(kind.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(engine == kind ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(engine == kind ? Color.accentColor.opacity(0.30) : Color.primary.opacity(0.06), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var voicePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("音色", icon: "person.wave.2")
            Picker("音色", selection: $voice) {
                ForEach(TTSConfig.voices) { v in
                    Text(v.label).tag(v.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .onChange(of: voice) { _, new in TTSConfig.voice = new }
        }
    }

    private var rateSlider: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("语速", icon: "gauge.with.dots.needle.50percent")
                Spacer()
                Text(rate >= 0 ? "+\(Int(rate))%" : "\(Int(rate))%")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $rate, in: -50...50, step: 5)
                .onChange(of: rate) { _, new in TTSConfig.ratePercent = Int(new) }
        }
    }

    private var azureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Azure 凭证", icon: "key.fill")
            VStack(alignment: .leading, spacing: 6) {
                Text("Region")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("如 eastasia / eastus", text: $azureRegion)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: azureRegion) { _, new in TTSConfig.azureRegion = new.trimmingCharacters(in: .whitespaces) }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Subscription Key")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if keySaved && azureKey.isEmpty {
                        Label("已保存", systemImage: "checkmark.seal.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
                SecureField(keySaved ? "已保存(留空不变)" : "粘贴 Azure Speech Key", text: $azureKey)
                    .textFieldStyle(.roundedBorder)
                Button {
                    saveKey()
                } label: {
                    Label("保存 Key", systemImage: "key.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .disabled(azureKey.isEmpty)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    if speech.speakingText == sampleText {
                        speech.stop()
                    } else {
                        speech.speak(sampleText)
                    }
                } label: {
                    let reading = speech.speakingText == sampleText
                    Label(reading ? (speech.preparing ? "合成中…" : "停止试听") : "试听",
                          systemImage: reading ? "stop.fill" : "play.fill")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                Text("用当前引擎与音色读一段示例。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if let note = speech.lastNote {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    private var noteSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Edge 引擎走微软非官方端点,免费但可能偶发失效 —— 失败会自动回退系统语音。",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private func sectionTitle(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline.weight(.bold))
    }

    private func saveKey() {
        do {
            try KeychainStore.save(id: TTSConfig.azureKeyID, apiKey: azureKey)
            azureKey = ""
            keySaved = true
        } catch {
            keySaved = false
        }
    }
}
