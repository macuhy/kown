#if os(iOS)
import Foundation
import SwiftUI
import UIKit
import Photos

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
    @State private var photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

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
                     ? "已把当前模型的地址、名称和 API Key 写入 App 共享容器,供键盘扩展使用;关闭开关即清除。在「Provider 配置」里点进某个模型可勾「设为键盘模型」指定用哪个。"
                     : "暂无可共享的模型:需要一个已启用、填好 API Key 的 OpenAI 兼容或 Anthropic 模型。")
                    .font(.caption2)
                    .foregroundStyle(synced ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().padding(.vertical, 2)

                // 截图回复:键盘打开自动读最近一张截图 → OCR → 生成回复。
                // 这里先取得完整照片权限,避免用户第一次进键盘时才被系统弹窗打断。
                Text("截图回复:开启后,键盘打开会自动识别你最近一张截图里的对话,直接生成回复。需要完整照片权限,「部分照片」无法自动读取未来的新截图。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                photoAccessControl
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear {
            enabled = KeyboardConfigBridge.isEnabled
            if enabled { synced = onToggle(true) }   // 进页面时顺手刷新一次共享配置
            photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        }
    }

    /// 相册授权:未决 → 请求按钮;完整授权 → 绿勾;部分授权/被拒 → 引导去系统设置。
    @ViewBuilder
    private var photoAccessControl: some View {
        switch photoStatus {
        case .authorized:
            Label("已允许完整照片权限", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        case .limited:
            HStack(spacing: 8) {
                Label("当前是部分照片权限,截图回复不可用", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Spacer(minLength: 4)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("改为完整访问", destination: url)
                        .font(.caption.weight(.semibold))
                }
            }
        case .denied, .restricted:
            HStack(spacing: 8) {
                Label("相册权限被关闭", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Spacer(minLength: 4)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("去系统设置", destination: url)
                        .font(.caption.weight(.semibold))
                }
            }
        default:   // .notDetermined
            Button {
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    Task { @MainActor in photoStatus = status }
                }
            } label: {
                Label("允许完整照片权限(生成回复用)", systemImage: "photo.on.rectangle.angled")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}
#endif
