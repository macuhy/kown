#if os(iOS)
import Foundation
import SwiftUI

/// 主 app → 键盘扩展(KownKeyboard)的配置桥。
///
/// 键盘扩展是独立进程,拿不到主 app 沙盒里的 apikeys.json / UserDefaults,
/// 只能经 App Group 共享容器传递。工程没配 keychain access group(iOS 上
/// App Group 不参与 Keychain 共享),所以用 **App Group UserDefaults** 存,
/// 设置页明确告知「key 会存放在 App 共享容器供键盘扩展使用」。
///
/// 开关关闭时立刻清除共享配置;provider 变更时由 AppViewModel.saveProviders 保持最新。
@MainActor
enum KeyboardConfigBridge {
    static let appGroupID = "group.com.xiaobo.kown"
    static let enabledKey = "kown.keyboard.bridge.enabled.v1"
    static let configKey  = "kown.keyboard.provider.v1"

    /// 写给键盘扩展的精简配置 —— 字段必须与 ios/Keyboard/KeyboardModel.swift
    /// 里的 `KeyboardProviderConfig` 保持一致(JSON 编码)。
    struct Payload: Codable {
        var name: String
        /// ProviderKind.rawValue:"openAICompatible" / "anthropic"
        var kind: String
        var baseURL: String
        var apiKey: String
        var model: String
    }

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupID) }

    /// 用户在设置页的「AI 键盘」开关(默认关)。
    static var isEnabled: Bool {
        get { defaults?.bool(forKey: enabledKey) ?? false }
        set { defaults?.set(newValue, forKey: enabledKey) }
    }

    /// 写入指定 provider 的连接信息。provider 为 nil / 类型不支持 / 没 key 时清空。
    /// 返回是否成功写入(给设置页反馈用)。
    @discardableResult
    static func sync(provider: ProviderConfig?) -> Bool {
        guard isEnabled,
              let p = provider,
              p.kind == .openAICompatible || p.kind == .anthropic,
              let key = try? KeychainStore.load(id: p.id), !key.isEmpty,
              let data = try? JSONEncoder().encode(Payload(name: p.displayName,
                                                           kind: p.kind.rawValue,
                                                           baseURL: p.baseURL,
                                                           apiKey: key,
                                                           model: p.model))
        else {
            clear()
            return false
        }
        defaults?.set(data, forKey: configKey)
        return true
    }

    static func clear() {
        defaults?.removeObject(forKey: configKey)
    }
}

/// 设置页「AI 键盘」卡片 —— SettingsView 里只挂一行,改动集中在本文件。
/// `onToggle` 由外部(AppViewModel)执行写入/清除,返回是否成功写入配置。
struct KeyboardBridgeSettingsCard: View {
    let onToggle: (Bool) -> Bool

    @State private var enabled = KeyboardConfigBridge.isEnabled
    @State private var synced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("AI 键盘", systemImage: "keyboard.badge.ellipsis")
                .font(.headline)
            Text("在任何 app 里切到 Kown 键盘,对正在输入的文字一键润色、翻译、生成回复。需先到 系统设置 → 通用 → 键盘 添加「Kown」并允许「完全访问」(联网必需)。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("共享模型配置给键盘", isOn: $enabled)
                .font(.subheadline)
                .onChange(of: enabled) { _, on in
                    synced = onToggle(on)
                }
            if enabled {
                Text(synced
                     ? "已把当前模型的地址、名称和 API Key 写入 App 共享容器,供键盘扩展使用;关闭开关即清除。"
                     : "暂无可共享的模型:需要一个已启用、填好 API Key 的 OpenAI 兼容或 Anthropic 模型。")
                    .font(.caption2)
                    .foregroundStyle(synced ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear {
            enabled = KeyboardConfigBridge.isEnabled
            if enabled { synced = onToggle(true) }   // 进页面时顺手刷新一次共享配置
        }
    }
}
#endif
