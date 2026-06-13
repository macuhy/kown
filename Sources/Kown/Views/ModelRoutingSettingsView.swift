import SwiftUI

/// Settings → 「模型路由」tab。把**个人口味盲测**(攒偏好画像)与 **Direct 模式的「用我的偏好」路由开关**
/// 放在一处:先盲测攒数据,再开开关让画像替你选模型。
///
/// 「用我的偏好」与「按难度自动选模型」(性能 tab)是两层并列路由,本页只管个人偏好这层;
/// 开启时个人偏好优先于难度/成本自动路由(见 `AppViewModel.send` 的路由层叠)。
struct ModelRoutingSettingsView: View {
    @Bindable var viewModel: AppViewModel

    /// 与 AppViewModel.preferenceRouteEnabled 同一 UserDefaults key,直接 AppStorage 绑定保持同步。
    @AppStorage(AppViewModel.preferenceRouteKey) private var preferenceRoute: Bool = false

    private let tint = Color(red: 0.46, green: 0.40, blue: 0.90)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                preferenceToggleCard
                // 盲测 + 偏好画像榜(自带 hero / 输入 / 对战 / 画像)。
                BlindTasteTestView(viewModel: viewModel)
            }
            .padding(.vertical, 4)
        }
        #if os(iOS)
        .scrollIndicators(.hidden)
        #endif
    }

    private var preferenceToggleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $preferenceRoute) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("用我的偏好选模型(Direct)")
                        .font(.body.weight(.semibold))
                    Text("Direct 模式发送时,按你的盲测偏好画像 + 问题任务类别,在当前模型所属厂商里自动换成「你更常选」的那个。样本不足时保持当前模型不变。开启时优先于「按难度自动选模型」。卡片会标注路由理由。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(tint)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.08), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.16), lineWidth: 1)
        }
        .padding(.horizontal, contentHPadding)
    }

    private var contentHPadding: CGFloat {
        #if os(iOS)
        return 14
        #else
        return 24
        #endif
    }
}
