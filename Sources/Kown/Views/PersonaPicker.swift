import SwiftUI

/// 输入栏的 Persona 选择入口(chip / 菜单)。
/// 未选时是普通圆形图标按钮;选中后变成「图标 + 名称」高亮 chip(对齐技能 / GitHub chip 风格)。
/// 选择按会话记忆(写 `Conversation.personaID`),与技能绑定互不影响。
struct PersonaPickerControl: View {
    @Bindable var viewModel: AppViewModel
    /// 与 InputBarView 的工具按钮同尺寸(macOS 30 / iOS 34)。
    var buttonSize: CGFloat = 30

    private static let tint = PersonaSettingsView.tint

    var body: some View {
        let active = viewModel.currentPersona
        Menu {
            menuContent(active: active)
        } label: {
            chipLabel(active: active)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .help(active == nil
              ? "Persona:选一个 Agent 档案(系统提示 + 模型 + 工具打包,按会话记忆)"
              : "本会话 Persona:\(active!.name)(再点可切换或取消)")
        #endif
        .accessibilityLabel(active == nil ? "选择 Persona" : "当前 Persona:\(active!.name)")
    }

    @ViewBuilder
    private func menuContent(active: Persona?) -> some View {
        Button {
            viewModel.setSelectedPersona(nil)
        } label: {
            if active == nil { Label("无 Persona", systemImage: "checkmark") }
            else { Text("无 Persona") }
        }
        if viewModel.personaStore.personas.isEmpty {
            Text("还没有 Persona,到 设置 ▸ Persona 创建")
        } else {
            Divider()
            ForEach(viewModel.personaStore.personas) { persona in
                Button {
                    viewModel.setSelectedPersona(persona.id)
                } label: {
                    if active?.id == persona.id {
                        Label(personaMenuTitle(persona), systemImage: "checkmark")
                    } else {
                        Text(personaMenuTitle(persona))
                    }
                }
            }
        }
    }

    private func personaMenuTitle(_ persona: Persona) -> String {
        persona.iconIsSystemSymbol || persona.icon.isEmpty
            ? persona.name
            : "\(persona.icon) \(persona.name)"
    }

    @ViewBuilder
    private func chipLabel(active: Persona?) -> some View {
        if let persona = active {
            HStack(spacing: 5) {
                personaGlyph(persona)
                Text(persona.name)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 110)
            }
            .foregroundStyle(Self.tint)
            .padding(.horizontal, 9)
            .frame(height: buttonSize)
            .background(Self.tint.opacity(0.13), in: Capsule())
            .overlay(Capsule().strokeBorder(Self.tint.opacity(0.28), lineWidth: 1))
        } else {
            Image(systemName: "theatermasks")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: buttonSize, height: buttonSize)
                .background { Circle().fill(Color.primary.opacity(0.05)) }
                .overlay { Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1) }
        }
    }

    @ViewBuilder
    private func personaGlyph(_ persona: Persona) -> some View {
        if persona.icon.isEmpty || persona.iconIsSystemSymbol {
            Image(systemName: persona.icon.isEmpty ? "theatermasks" : persona.icon)
                .font(.system(size: 11, weight: .bold))
        } else {
            Text(persona.icon)
                .font(.system(size: 13))
        }
    }
}

#if os(iOS)
/// iOS「更多」菜单里的 Persona 选择分节(与技能绑定菜单同级)。
struct PersonaMenuSection: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        let active = viewModel.currentPersona
        Menu {
            Button {
                viewModel.setSelectedPersona(nil)
            } label: {
                if active == nil { Label("无 Persona", systemImage: "checkmark") }
                else { Text("无 Persona") }
            }
            if viewModel.personaStore.personas.isEmpty {
                Text("还没有 Persona")
            } else {
                Divider()
                ForEach(viewModel.personaStore.personas) { persona in
                    Button {
                        viewModel.setSelectedPersona(persona.id)
                    } label: {
                        if active?.id == persona.id {
                            Label(persona.name, systemImage: "checkmark")
                        } else {
                            Text(persona.name)
                        }
                    }
                }
            }
        } label: {
            Label(active == nil ? "Persona：未启用" : "Persona：\(active?.name ?? "")",
                  systemImage: "theatermasks")
        }
    }
}
#endif
