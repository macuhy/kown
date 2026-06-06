import SwiftUI

/// 输入栏里的「GitHub 仓库」按钮:
/// - 已绑定仓库 → 显示 owner/repo chip,点开切仓库菜单,✕ 解绑;
/// - 已连接未绑定 → 菜单列出仓库供选择;
/// - 未连接 → 点击发起设备码授权(code 由 RootView 上的 sheet 展示)。
/// macOS + iOS 通用(GitHub 走网络,不像本地 workspace 受平台限制)。
struct GitHubRepoButton: View {
    @Bindable var viewModel: AppViewModel
    var tint: Color

    var body: some View {
        if let repo = viewModel.currentGitHubRepo {
            selectedRepoControl(repo)
        } else if viewModel.gitHubConnected {
            repoMenu(label: repoPickerLabel)
        } else {
            connectButton
        }
    }

    // MARK: 仓库选择菜单

    @ViewBuilder
    private func selectedRepoControl(_ repo: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                repoMenu(label: chipLabel(repo, text: repo, maxTextWidth: 150))
                clearRepoButton
            }

            HStack(spacing: 4) {
                repoMenu(label: chipLabel(repo, text: repoShortName(repo), maxTextWidth: 96))
                clearRepoButton
            }

            repoMenu(label: iconOnlyLabel("arrow.triangle.branch", accessibilityLabel: "GitHub 仓库: \(repo)"))
        }
        .help("当前 GitHub 仓库: \(repo)")
    }

    private var repoPickerLabel: some View {
        ViewThatFits(in: .horizontal) {
            iconLabel("arrow.triangle.branch", text: "选仓库")
            iconOnlyLabel("arrow.triangle.branch", accessibilityLabel: "选择 GitHub 仓库")
        }
    }

    private var connectButton: some View {
        Button {
            viewModel.startGitHubDeviceFlow()
        } label: {
            ViewThatFits(in: .horizontal) {
                iconLabel("arrow.triangle.branch", text: "连 GitHub")
                iconOnlyLabel("arrow.triangle.branch", accessibilityLabel: "连接 GitHub")
            }
        }
        .buttonStyle(.plain)
        .help("连接 GitHub — 把定稿内容直接提交到仓库")
        .accessibilityLabel("连接 GitHub")
    }

    private var clearRepoButton: some View {
        Button {
            viewModel.clearGitHubRepo()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
                .frame(width: 24, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("解除 GitHub 仓库绑定")
        .accessibilityLabel("解除 GitHub 仓库绑定")
    }

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
                        let title = repoMenuTitle(repo.fullName)
                        if viewModel.currentGitHubRepo == repo.fullName {
                            Label("\(title)\(repo.isPrivate ? " 🔒" : "")", systemImage: "checkmark")
                        } else {
                            Text("\(title)\(repo.isPrivate ? " 🔒" : "")")
                        }
                    }
                    .help(repo.fullName)
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
        .task { await viewModel.loadGitHubRepos() }
        .accessibilityLabel("GitHub 仓库菜单")
    }

    private func chipLabel(_ repo: String, text: String, maxTextWidth: CGFloat) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .bold))
            Text(text)
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: maxTextWidth, alignment: .leading)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(tint.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.26), lineWidth: 1))
        .accessibilityLabel("GitHub 仓库: \(repo)")
    }

    private func iconLabel(_ symbol: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
            Text(text)
                .font(.caption.weight(.bold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(tint.opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.20), lineWidth: 1))
    }

    private func iconOnlyLabel(_ symbol: String, accessibilityLabel: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(tint.opacity(0.10), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.20), lineWidth: 1))
            .accessibilityLabel(accessibilityLabel)
    }

    private func repoShortName(_ repo: String) -> String {
        if let leaf = repo.split(separator: "/", omittingEmptySubsequences: true).last, !leaf.isEmpty {
            return String(leaf)
        }
        return repo
    }

    private func repoMenuTitle(_ fullName: String) -> String {
        abbreviatedMiddle(fullName, maxCharacters: 58)
    }

    private func abbreviatedMiddle(_ value: String, maxCharacters: Int) -> String {
        guard value.count > maxCharacters, maxCharacters > 12 else { return value }
        let headCount = max(6, (maxCharacters - 1) / 2)
        let tailCount = max(6, maxCharacters - headCount - 1)
        return "\(value.prefix(headCount))…\(value.suffix(tailCount))"
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
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Platform.copyText(device.userCode)
                withAnimation { copied = true }
            } label: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        deviceCodeText
                        copyStateIcon
                    }

                    VStack(spacing: 8) {
                        deviceCodeText
                        copyStateIcon
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(Color.platformTextBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("点击复制验证码")
            .accessibilityLabel("复制 GitHub 验证码 \(device.userCode)")

            Button {
                if let url = URL(string: device.verificationURI) { Platform.open(url) }
            } label: {
                Label {
                    Text(device.verificationURI)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.leading)
                } icon: {
                    Image(systemName: "safari")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help(device.verificationURI)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    waitingText
                }

                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    waitingText
                }
            }
            .padding(.top, 4)

            Button("取消", role: .cancel) { onCancel() }
                .controlSize(.regular)
                .fixedSize()
                .padding(.top, 2)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: 420)
    }

    private var deviceCodeText: some View {
        Text(device.userCode)
            .font(.system(.title, design: .monospaced).weight(.bold))
            .tracking(2)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
    }

    private var copyStateIcon: some View {
        Image(systemName: copied ? "checkmark" : "doc.on.doc")
            .foregroundStyle(copied ? .green : .secondary)
    }

    private var waitingText: some View {
        Text("等待授权完成…")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// 设置页里的「GitHub」区块:连接状态 + 连接 / 断开按钮 + 错误提示。
struct GitHubConnectionCard: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    cardTitle
                    Spacer(minLength: 12)
                    connectionAction
                }

                VStack(alignment: .leading, spacing: 14) {
                    cardTitle
                    connectionAction
                }
            }
            if let err = viewModel.gitHubError, !err.isEmpty {
                errorMessage(err)
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

    private var cardTitle: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.title3.weight(.bold))
                .foregroundStyle(.teal)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text("GitHub")
                    .font(.headline)
                Text(viewModel.gitHubConnected ? "已连接 — 对话时可在输入栏选仓库,把定稿内容直接提交" : "连接后可把最终内容直接提交到你的仓库")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var connectionAction: some View {
        if viewModel.gitHubConnected {
            Button(role: .destructive) {
                viewModel.disconnectGitHub()
            } label: {
                Label("断开", systemImage: "xmark.circle")
            }
            .controlSize(.regular)
            .fixedSize(horizontal: true, vertical: false)
        } else {
            Button {
                viewModel.startGitHubDeviceFlow()
            } label: {
                Label("连接", systemImage: "link")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func errorMessage(_ err: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("GitHub 连接提示", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
            ViewThatFits(in: .horizontal) {
                Text(err)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(err)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .textSelection(.enabled)
                }
            }
        }
        .foregroundStyle(.red)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.red.opacity(0.18), lineWidth: 1)
        }
    }
}
