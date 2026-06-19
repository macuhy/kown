import SwiftUI

struct SecretStoreSettingsView: View {
    @Bindable var viewModel: AppViewModel
    @State private var isWorking = false
    @State private var pendingTarget: SecretStoreBackendKind?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroCard
                backendCards
                migrationActions
                bridgeNotes
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .topLeading)
        }
        .scrollIndicators(.automatic)
        .onAppear { viewModel.refreshSecretStoreStatus() }
        .confirmationDialog(
            "迁移 API Key 存储?",
            isPresented: Binding(
                get: { pendingTarget != nil },
                set: { if !$0 { pendingTarget = nil } }
            ),
            presenting: pendingTarget
        ) { target in
            Button("复制并启用 \(target.displayName)") {
                migrate(to: target)
            }
            Button("取消", role: .cancel) {
                pendingTarget = nil
            }
        } message: { target in
            Text("会先复制并回读校验当前 key,成功后才切换到 \(target.displayName)。原存储不会被删除。")
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.teal.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text("密钥存储")
                        .font(.title2.weight(.bold))
                    Text("API Key、GitHub token、TTS 凭据都走同一个本机 secret-store facade。默认 JSON 不随 iCloud 同步;系统 Keychain 需要你手动迁移启用。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                statusPill(viewModel.secretStoreBackendKind.displayName, icon: "internaldrive", color: .teal)
                statusPill(keyCountText, icon: "number", color: .secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.teal.opacity(0.22), lineWidth: 1)
        }
    }

    private var backendCards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
            ForEach(SecretStoreBackendKind.allCases) { kind in
                backendCard(kind)
            }
        }
    }

    private func backendCard(_ kind: SecretStoreBackendKind) -> some View {
        let selected = viewModel.secretStoreBackendKind == kind
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: kind == .localJSON ? "doc.text.fill" : "lock.shield.fill")
                    .foregroundStyle(selected ? .white : .teal)
                    .frame(width: 28, height: 28)
                    .background((selected ? Color.teal : Color.teal.opacity(0.12)), in: Circle())
                Text(kind.displayName)
                    .font(.headline)
                Spacer()
                if selected {
                    Label("当前", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }

            Text(kind.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if kind == .securityKeychain && !kind.isAvailableOnThisPlatform {
                Label("当前平台不可用", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.teal.opacity(0.10) : Color.platformTextBackground.opacity(0.28),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder((selected ? Color.teal : Color.primary).opacity(selected ? 0.32 : 0.08), lineWidth: 1)
        }
    }

    private var migrationActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("显式迁移")
                .font(.headline)
            Text("迁移只复制和校验,不会删除原 JSON 或原 Keychain 项。失败时保持当前后端不变。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    pendingTarget = .securityKeychain
                } label: {
                    Label("复制并启用系统 Keychain", systemImage: "lock.shield")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || viewModel.secretStoreBackendKind == .securityKeychain || !KeychainStore.supportsSecurityKeychain)

                Button {
                    pendingTarget = .localJSON
                } label: {
                    Label("复制并切回 JSON", systemImage: "doc.text")
                }
                .buttonStyle(.bordered)
                .disabled(isWorking || viewModel.secretStoreBackendKind == .localJSON)

                if isWorking {
                    ProgressView().controlSize(.small)
                }
            }

            if let message = viewModel.secretStoreMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let error = viewModel.secretStoreError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var bridgeNotes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("跨端注意", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)
            Text("iOS 键盘扩展和 Apple Watch 不能直接读取主 app 的本机 secret store。启用系统 Keychain 后,主 app 仍会在你打开相应开关时把选定模型 key 复制到 App Group / WatchConnectivity 桥接通道。")
            Text("若桥接开关关闭,这些扩展不会自动拿到新后端里的 key;需要在设置里重新同步或手动配置。")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var keyCountText: String {
        if let count = viewModel.secretStoreKeyCount {
            return "\(count) 个 key"
        }
        return "读取失败"
    }

    private func statusPill(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }

    private func migrate(to target: SecretStoreBackendKind) {
        pendingTarget = nil
        isWorking = true
        defer { isWorking = false }
        do {
            switch target {
            case .localJSON:
                _ = try viewModel.migrateSecretStoreToLocalJSON()
            case .securityKeychain:
                _ = try viewModel.migrateSecretStoreToSecurityKeychain()
            }
        } catch {
            viewModel.secretStoreError = error.localizedDescription
        }
    }
}
