import SwiftUI

/// 朗读(TTS)设置:选引擎(硅基流动 / 讯飞 / 系统)/ 音色 / 语速,凭证,试听。
struct TTSSettingsView: View {
    @State private var engine: TTSEngineKind = TTSConfig.engine
    @State private var voice: String = TTSConfig.voice
    @State private var rate: Double = Double(TTSConfig.ratePercent)
    @State private var sfKey: String = ""
    @State private var sfKeySaved: Bool = false
    @State private var xfAppID: String = TTSConfig.xunfeiAppID
    @State private var xfAPIKey: String = ""
    @State private var xfAPISecret: String = ""
    @State private var xfSaved: Bool = false

    @ObservedObject private var speech = SpeechService.shared

    private let sampleText = "你好,我是 Kown 的朗读语音。这是一段试听示例,用来听听音色和语速是否合适。"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                enginePicker
                if engine == .siliconflow {
                    siliconflowSection
                }
                if engine == .xunfei {
                    xunfeiSection
                }
                if engine != .system {
                    voicePicker
                    rateSlider
                }
                previewSection
                noteSection
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .onAppear {
            sfKeySaved = TTSConfig.siliconflowKey?.isEmpty == false
            xfSaved = (TTSConfig.xunfeiAPIKey?.isEmpty == false) && (TTSConfig.xunfeiAPISecret?.isEmpty == false)
        }
    }

    private var enginePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("朗读引擎", icon: "waveform")
            ForEach(TTSEngineKind.allCases) { kind in
                Button {
                    engine = kind
                    TTSConfig.engine = kind
                    voice = TTSConfig.voice(for: kind)
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
                ForEach(TTSConfig.voices(for: engine)) { v in
                    Text(v.label).tag(v.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .onChange(of: voice) { _, new in TTSConfig.setVoice(new, for: engine) }
        }
    }

    private var siliconflowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("硅基流动凭证", icon: "key.fill")
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("API Key")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if sfKeySaved && sfKey.isEmpty {
                        Label("已保存", systemImage: "checkmark.seal.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
                SecureField(sfKeySaved ? "已保存(留空不变)" : "粘贴 SiliconFlow Key(sk-…)", text: $sfKey)
                    .textFieldStyle(.roundedBorder)
                Button {
                    saveSiliconflowKey()
                } label: {
                    Label("保存 Key", systemImage: "key.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .disabled(sfKey.isEmpty)
                Text("在 siliconflow.cn 注册即可拿 key(新用户送额度);国内直连,无需 VPN。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var xunfeiSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("讯飞凭证", icon: "key.fill")
            VStack(alignment: .leading, spacing: 6) {
                Text("APPID")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("讯飞应用 APPID", text: $xfAppID)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: xfAppID) { _, new in TTSConfig.xunfeiAppID = new.trimmingCharacters(in: .whitespaces) }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("APIKey / APISecret")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if xfSaved && xfAPIKey.isEmpty && xfAPISecret.isEmpty {
                        Label("已保存", systemImage: "checkmark.seal.fill")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.green)
                    }
                }
                SecureField(xfSaved ? "APIKey 已保存(留空不变)" : "粘贴 APIKey", text: $xfAPIKey)
                    .textFieldStyle(.roundedBorder)
                SecureField(xfSaved ? "APISecret 已保存(留空不变)" : "粘贴 APISecret", text: $xfAPISecret)
                    .textFieldStyle(.roundedBorder)
                Button {
                    saveXunfei()
                } label: {
                    Label("保存凭证", systemImage: "key.fill").font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .disabled(xfAPIKey.isEmpty && xfAPISecret.isEmpty)
                Text("在 xfyun.cn 开通「在线语音合成」拿 APPID/APIKey/APISecret(每日 500 次免费)。按次计费,Kown 会把整段尽量一次合成以省次数。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            Label("硅基流动 / 讯飞均为国内直连;合成失败会自动回退系统语音。朗读配置随 iCloud 同步。",
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

    private func saveSiliconflowKey() {
        do {
            try KeychainStore.save(id: TTSConfig.siliconflowKeyID, apiKey: sfKey)
            sfKey = ""
            sfKeySaved = true
        } catch {
            sfKeySaved = false
        }
    }

    private func saveXunfei() {
        if !xfAPIKey.isEmpty { try? KeychainStore.save(id: TTSConfig.xunfeiAPIKeyID, apiKey: xfAPIKey) }
        if !xfAPISecret.isEmpty { try? KeychainStore.save(id: TTSConfig.xunfeiAPISecretID, apiKey: xfAPISecret) }
        xfAPIKey = ""
        xfAPISecret = ""
        xfSaved = (TTSConfig.xunfeiAPIKey?.isEmpty == false) && (TTSConfig.xunfeiAPISecret?.isEmpty == false)
    }
}
