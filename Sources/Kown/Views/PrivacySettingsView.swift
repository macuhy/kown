import SwiftUI

/// 设置 ▸ 隐私脱敏(PII redaction)。
/// - 总开关(默认关,隐私功能 opt-in):开后发往**云端** LLM 前,本地检测并假名化 PII
///   (手机号 / 邮箱 / 身份证号 / 银行卡号,可选人名),发送占位符;模型返回时再把占位符还原成原文展示 / 存储。
/// - 分类开关:逐类控制脱敏哪些信息。
/// - 本地模型(Ollama / localhost / CLI)**自动跳过**脱敏 —— 数据没出本机,无需假名化。
///
/// 持久化:全部走 `@AppStorage`(UserDefaults),与 `PIIRedactor` 读的 key 一一对应。
struct PrivacySettingsView: View {
    @AppStorage(PIIRedactor.enabledKey) private var enabled = false
    @AppStorage(PIIRedactor.phoneKey)   private var phone   = true
    @AppStorage(PIIRedactor.emailKey)   private var email   = true
    @AppStorage(PIIRedactor.idCardKey)  private var idCard  = true
    @AppStorage(PIIRedactor.bankKey)    private var bank    = true
    @AppStorage(PIIRedactor.nameKey)    private var name    = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                masterCard
                if enabled {
                    categoriesCard
                }
                localNoteCard
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - 总开关

    private var masterCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $enabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("启用隐私脱敏")
                        .font(.callout.weight(.semibold))
                    Text("开启后:发往云端模型前,在本机把手机号 / 邮箱 / 身份证 / 银行卡(可选人名)替换成占位符(如「[电话1]」),模型返回时再自动还原成原文。每次请求一份可逆映射,原文不会离开本机。默认关闭。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !enabled {
                Label("当前关闭:发送内容原样发往云端模型。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    // MARK: - 分类开关

    private var categoriesCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("脱敏哪些信息")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            categoryToggle("手机号 / 电话", systemImage: "phone.fill", isOn: $phone)
            Divider()
            categoryToggle("邮箱地址", systemImage: "envelope.fill", isOn: $email)
            Divider()
            categoryToggle("身份证号", systemImage: "person.text.rectangle.fill", isOn: $idCard)
            Divider()
            categoryToggle("银行卡 / 信用卡号", systemImage: "creditcard.fill", isOn: $bank)
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                categoryToggle("人名", systemImage: "person.fill", isOn: $name)
                Text("基于本机命名实体识别,准确率不及结构化信息,可能漏报或误报,默认关闭。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func categoryToggle(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: systemImage)
                .font(.callout)
        }
    }

    // MARK: - 本地模型说明

    private var localNoteCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.laptopcomputer")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("本地模型自动跳过脱敏")
                    .font(.caption.weight(.semibold))
                Text("Ollama、指向 localhost / 内网的 OpenAI 兼容服务,以及命令行 CLI provider 都在本机运行,数据不出设备,因此不会做假名化 —— 你拿到的还是原始上下文。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }
}
