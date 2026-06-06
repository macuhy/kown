import SwiftUI

/// 输入栏里的「GitHub 仓库」按钮:
/// - 已绑定仓库 → 显示 owner/repo chip,点开切仓库菜单,✕ 解绑;
/// - 已连接��绑定 → 菜单列出仓库供选择;
/// - 未连接 → 点击发起设备码授权(code 由 RootView 上的 sheet 展示)。
/// macOS + iOS 通用(GitHub 走网络,不像本地 workspace 受平台限制)。
struct GitHubRepoButton: View {
    @Bindable var viewModel: AppViewModel
    var tint: Color

    var body: some View {
        if let repo = viewModel.currentGitHubRepo {
            HStack(spacing: 4) {
                repoMenu(label: chipLabel(repo))
                Button {
                    viewModel.clearGitHubRepo()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .frame(width: 22, height: 30)
                }
                .buttonStyle(.plain)
                .help("解除 GitHub 仓库绑定")
            }
        } else if viewModel.gitHubConnected {
            repoMenu(label: iconLabel("arrow.triangle.branch", text: "选仓库"))
        } else {
            Button {
                viewModel.startGitHubDeviceFlow()
            } label: {
                iconLabel("arrow.triangle.branch", text: "连 GitHub")
            }
            .buttonStyle(.plain)
            .help("连接 GitHub — 把定稿内容直接提交到仓库")
        }
    }

    // MARK: 仓库选择菜单

    @ViewBuilder
    private func repoMenu(label: some View) -> some View {
        Menu {
            if viewModel.gitHubReposLoading {
                Text("加载仓库中…")
            } else if viewModel.gitHubRepos.isEmpty {
                Text("没有可用仓库")
                Button("重新加载") { Task { await viewModel.loadGitHubRepos(force: true) } }
            } else {
                ForEach(viewModel.gitHubRepos) { repo in
                    Button {
                        viewModel.setGitHubRepo(repo)
                    } label: {
                        if viewModel.currentGitHubRepo == repo.fullName {
                            Label("\(repo.fullName)\(repo.isPrivate ? " 🔒" : "")", systemImage: "checkmark")
                        } else {
                            Text("\(repo.fullName)\(repo.isPrivate ? " 🔒" : "")")
                        }
                    }
                }
            }
            Divider()
            if viewModel.currentGitHubRepo != nil {
                Button("解除绑定", role: .destructive) { viewModel.clearGitHubRepo() }
            }
        } label: {
            label
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .task { await viewModel.loadGitHubRepos() }
    }

    private func chipLabel(_ repo: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .bold))
            Text((repo as NSString).lastPathComponent)
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 130)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(tint.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.26), lineWidth: 1))
    }

    private func iconLabel(_ symbol: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
            Text(text).font(.caption.weight(.bold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(tint.opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.20), lineWidth: 1))
    }
}

/// 设备码授权进行中的弹窗:展示 user code + 验证链接,等待用户在浏览器确认。
struct GitHubDeviceCodeSheet: View {
    let device: GitHubDeviceCode
    var onCancel: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.teal)
            Text("连接 GitHub")
                .font(.title3.weight(.bold))
            Text("在浏览器打开下面的链接,输入这个验证码完成授权:")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Platform.copyText(device.userCode)
                withAnimation { copied = true }
            } label: {
                HStack(spacing: 10) {
                    Text(device.userCode)
                        .font(.system(.title, design: .monospaced).weight(.bold))
                        .tracking(2)
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? .green : .secondary)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(Color.platformTextBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("点击复制验证码")

            Button {
                if let url = URL(string: device.verificationURI) { Platform.open(url) }
            } label: {
                Label(device.verificationURI, systemImage: "safari")
                    .font(.callout.weight(.semibold))
            }

            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("等待授权完成…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)

            Button("取消", role: .cancel) { onCancel() }
                .padding(.top, 2)
        }
        .padding(28)
        .frame(maxWidth: 380)
    }
}

/// 设置页里的「GitHub」区块:连接状态 + 连接 / 断开按钮 + 错误提示。
struct GitHubConnectionCard: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("GitHub")
                        .font(.headline)
                    Text(viewModel.gitHubConnected ? "已连接 — 对话时可在输入栏选仓库,把定稿内容直接提交" : "连接后可把最终内容直接提交到你的仓库")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.gitHubConnected {
                    Button("断开", role: .destructive) { viewModel.disconnectGitHub() }
                } else {
                    Button("连接") { viewModel.startGitHubDeviceFlow() }
                        .buttonStyle(.borderedProminent)
                }
            }
            if let err = viewModel.gitHubError, !err.isEmpty {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.teal.opacity(0.22), lineWidth: 1)
        }
    }
}
