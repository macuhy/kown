import Foundation

/// GitHub 集成的 ViewModel 入口:设备码授权、仓库列表、会话级仓库绑定。
@MainActor
extension AppViewModel {

    /// 当前选中会话绑定的 GitHub 仓库 "owner/repo"(未绑定为 nil)。
    var currentGitHubRepo: String? { selectedConversation?.gitHubRepo }

    // MARK: - Device Flow 授权

    /// 开始 GitHub 设备码授权:先拿 code 展示给用户,再后台轮询直到授权完成。
    /// 成功后保存 token、刷新连接状态并预拉仓库列表。
    func startGitHubDeviceFlow() {
        gitHubError = nil
        gitHubFlowTask?.cancel()
        gitHubFlowTask = Task { @MainActor in
            do {
                let device = try await GitHubClient.requestDeviceCode()
                if Task.isCancelled { return }
                self.gitHubPendingDeviceCode = device
                let token = try await GitHubClient.pollForToken(device)
                try GitHubAuth.saveToken(token)
                self.gitHubPendingDeviceCode = nil
                self.gitHubConnected = true
                await self.loadGitHubRepos(force: true)
            } catch is CancellationError {
                self.gitHubPendingDeviceCode = nil
            } catch {
                self.gitHubPendingDeviceCode = nil
                self.gitHubError = error.localizedDescription
            }
            self.gitHubFlowTask = nil
        }
    }

    /// 取消正在进行的设备码授权:真正 cancel 轮询 Task(pollForToken 在下个 tick 抛 CancellationError)+ 清 UI 状态。
    func cancelGitHubDeviceFlow() {
        gitHubFlowTask?.cancel()
        gitHubFlowTask = nil
        gitHubPendingDeviceCode = nil
    }

    /// 断开 GitHub:删 token、清缓存、解绑所有会话的仓库选择。
    func disconnectGitHub() {
        gitHubFlowTask?.cancel()
        gitHubFlowTask = nil
        GitHubAuth.disconnect()
        gitHubConnected = false
        gitHubRepos = []
        gitHubPendingDeviceCode = nil
        gitHubError = nil
    }

    // MARK: - 仓库列表

    /// 拉取当前用户的仓库列表并缓存。`force=false` 时已有缓存就跳过。
    func loadGitHubRepos(force: Bool = false) async {
        guard gitHubConnected, let token = GitHubAuth.token() else { return }
        if !force, !gitHubRepos.isEmpty { return }
        gitHubReposLoading = true
        gitHubError = nil
        defer { gitHubReposLoading = false }
        do {
            let repos = try await GitHubClient(token: token).listRepos()
            gitHubRepos = repos
        } catch {
            gitHubError = error.localizedDescription
        }
    }

    // MARK: - 会话级绑定

    /// 给当前会话绑定一个 GitHub 仓库(同时记录其默认分支)。
    func setGitHubRepo(_ repo: GitHubRepo) {
        guard let convID = selectedConversationID,
              let idx = conversations.firstIndex(where: { $0.id == convID }) else { return }
        conversations[idx].gitHubRepo = repo.fullName
        conversations[idx].gitHubBranch = repo.defaultBranch
        conversations[idx].updatedAt = Date()
        ConversationStore.save(conversations[idx])
    }

    /// 解除当前会话的 GitHub 仓库绑定。
    func clearGitHubRepo() {
        guard let convID = selectedConversationID,
              let idx = conversations.firstIndex(where: { $0.id == convID }) else { return }
        conversations[idx].gitHubRepo = nil
        conversations[idx].gitHubBranch = nil
        conversations[idx].updatedAt = Date()
        ConversationStore.save(conversations[idx])
    }
}
