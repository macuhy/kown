import Foundation

/// GitHub 集成:OAuth Device Flow 登录 + Contents API 读写文件。
///
/// 设计:
/// - **认证走 Device Flow**(只需 client_id,无 client secret,适合客户端):
///   App 显示一个 user_code + 验证链接,用户在浏览器确认后轮询拿到 token。
/// - **token 存 `KeychainStore`**(固定 UUID),跟其它 API key 一样落 apikeys.json。
/// - **写文件走 Contents API**:PUT /repos/{owner}/{repo}/contents/{path}。更新已有文件需带旧 `sha`,
///   所以写前先 GET 一次拿 sha + 旧内容(旧内容也用于在聊天里算 diff 行数)。
enum GitHubAuth {
    /// 在 GitHub 注册的 OAuth App(已开启 Device Flow)的 Client ID。非机密,可硬编码进客户端。
    static let clientID = "Ov23li0qCXvbdu8tcru1"
    /// 授权范围:`repo` 才能读写私有仓库(OAuth App 没有更细粒度)。
    static let scope = "repo"
    /// token 在 KeychainStore 里的固定 key。(必须是合法十六进制 UUID — 历史上误用非 hex 串导致启动崩溃。)
    static let tokenID = UUID(uuidString: "C0FFEE00-0000-4000-8000-000000000001")!

    @MainActor static func token() -> String? {
        let t = try? KeychainStore.load(id: tokenID)
        return (t?.isEmpty == false) ? t : nil
    }
    @MainActor static func isConnected() -> Bool { token() != nil }
    @MainActor static func saveToken(_ token: String) throws { try KeychainStore.save(id: tokenID, apiKey: token) }
    @MainActor static func disconnect() { KeychainStore.delete(id: tokenID) }
}

enum GitHubError: Error, LocalizedError {
    case http(status: Int, body: String)
    case decoding(String)
    case authPending
    case slowDown
    case denied
    case expired
    case notConnected

    var errorDescription: String? {
        switch self {
        case .http(let s, let b): return "GitHub 请求失败 (\(s)): \(b)"
        case .decoding(let m):    return "解析 GitHub 响应失败: \(m)"
        case .authPending:        return "等待授权中…"
        case .slowDown:           return "轮询过快,已降速"
        case .denied:             return "用户拒绝了授权"
        case .expired:            return "设备码已过期,请重新连接"
        case .notConnected:       return "未连接 GitHub,请先在设置里连接"
        }
    }
}

// MARK: - Device Flow

/// 设备码授权第一步的返回:展示给用户的 code + 链接,以及轮询参数。
struct GitHubDeviceCode: Sendable, Identifiable {
    let deviceCode: String
    let userCode: String
    let verificationURI: String
    let interval: Int
    let expiresIn: Int
    var id: String { deviceCode }
}

// MARK: - Models

struct GitHubRepo: Identifiable, Sendable, Hashable {
    /// "owner/repo"
    let fullName: String
    let defaultBranch: String
    let isPrivate: Bool
    var id: String { fullName }
}

/// 一次写文件后的提交结果。
struct GitHubCommit: Sendable {
    /// 提交 SHA
    let sha: String
    /// commit 在网页上的地址(给用户点开看)
    let htmlURL: String
}

/// 读文件返回:旧内容 + sha(更新时回传)。文件不存在时 sha/content 均为 nil。
struct GitHubFile: Sendable {
    let sha: String?
    let content: String?
}

/// GitHub REST 客户端。无可变状态,Sendable。
struct GitHubClient: Sendable {
    let token: String

    private static let api = "https://api.github.com"

    // MARK: Device Flow（静态，无需 token）

    /// 第一步:申请设备码。POST https://github.com/login/device/code
    static func requestDeviceCode() async throws -> GitHubDeviceCode {
        var req = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = "client_id=\(GitHubAuth.clientID)&scope=\(GitHubAuth.scope)"
        req.httpBody = Data(form.utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.checkStatus(resp, data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = json["device_code"] as? String,
              let user = json["user_code"] as? String,
              let uri = json["verification_uri"] as? String else {
            throw GitHubError.decoding("device code 响应缺字段")
        }
        return GitHubDeviceCode(
            deviceCode: device, userCode: user, verificationURI: uri,
            interval: (json["interval"] as? Int) ?? 5,
            expiresIn: (json["expires_in"] as? Int) ?? 900
        )
    }

    /// 第二步:轮询直到用户授权完成,返回 access token。
    /// 处理 GitHub 的 authorization_pending / slow_down / expired_token / access_denied。
    static func pollForToken(_ device: GitHubDeviceCode) async throws -> String {
        var interval = max(device.interval, 1)
        let deadline = Date().addingTimeInterval(TimeInterval(device.expiresIn))
        while Date() < deadline {
            if Task.isCancelled { throw CancellationError() }
            try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            do {
                return try await Self.exchangeOnce(deviceCode: device.deviceCode)
            } catch GitHubError.authPending {
                continue
            } catch GitHubError.slowDown {
                interval += 5
                continue
            }
        }
        throw GitHubError.expired
    }

    private static func exchangeOnce(deviceCode: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = "client_id=\(GitHubAuth.clientID)&device_code=\(deviceCode)"
            + "&grant_type=urn:ietf:params:oauth:grant-type:device_code"
        req.httpBody = Data(form.utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError.decoding("token 响应非 JSON")
        }
        if let token = json["access_token"] as? String, !token.isEmpty {
            return token
        }
        switch json["error"] as? String {
        case "authorization_pending": throw GitHubError.authPending
        case "slow_down":             throw GitHubError.slowDown
        case "access_denied":         throw GitHubError.denied
        case "expired_token":         throw GitHubError.expired
        default:                      throw GitHubError.decoding((json["error"] as? String) ?? "未知错误")
        }
    }

    // MARK: 仓库 / 文件（带 token）

    /// 列出当前用户可写的仓库(按最近更新排序,取前 100 个）。
    func listRepos() async throws -> [GitHubRepo] {
        let url = URL(string: "\(Self.api)/user/repos?per_page=100&sort=updated&affiliation=owner,collaborator,organization_member")!
        let data = try await get(url)
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw GitHubError.decoding("repos 响应非数组")
        }
        return arr.compactMap { item in
            guard let full = item["full_name"] as? String else { return nil }
            return GitHubRepo(
                fullName: full,
                defaultBranch: (item["default_branch"] as? String) ?? "main",
                isPrivate: (item["private"] as? Bool) ?? false
            )
        }
    }

    /// 读文件,拿 sha + 旧内容(用于更新时回传 sha + 算 diff)。文件不存在返回空。
    func getFile(owner: String, repo: String, path: String, branch: String) async throws -> GitHubFile {
        let p = path.split(separator: "/").map { Self.escape(String($0)) }.joined(separator: "/")
        let url = URL(string: "\(Self.api)/repos/\(owner)/\(repo)/contents/\(p)?ref=\(Self.escape(branch))")!
        let req = authedRequest(url: url)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 404 {
            return GitHubFile(sha: nil, content: nil)  // 新建
        }
        try Self.checkStatus(resp, data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError.decoding("contents 响应非对象")
        }
        let sha = json["sha"] as? String
        var content: String? = nil
        if let b64 = json["content"] as? String {
            let cleaned = b64.replacingOccurrences(of: "\n", with: "")
            if let raw = Data(base64Encoded: cleaned) {
                content = String(data: raw, encoding: .utf8)
            }
        }
        return GitHubFile(sha: sha, content: content)
    }

    /// 写文件(PUT contents)。更新已有文件需带 `sha`;新建传 nil。返回提交信息。
    func putFile(owner: String, repo: String, path: String,
                 content: String, message: String, branch: String, sha: String?) async throws -> GitHubCommit {
        let p = path.split(separator: "/").map { Self.escape(String($0)) }.joined(separator: "/")
        let url = URL(string: "\(Self.api)/repos/\(owner)/\(repo)/contents/\(p)")!
        var req = authedRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "message": message,
            "content": Data(content.utf8).base64EncodedString(),
            "branch": branch
        ]
        if let sha { body["sha"] = sha }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.checkStatus(resp, data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commit = json["commit"] as? [String: Any] else {
            throw GitHubError.decoding("put 响应缺 commit")
        }
        let sha = (commit["sha"] as? String) ?? ""
        let html = (commit["html_url"] as? String)
            ?? ((json["content"] as? [String: Any])?["html_url"] as? String)
            ?? "https://github.com/\(owner)/\(repo)"
        return GitHubCommit(sha: sha, htmlURL: html)
    }

    // MARK: helpers

    private func authedRequest(url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("Kown", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        return req
    }

    private func get(_ url: URL) async throws -> Data {
        let req = authedRequest(url: url)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.checkStatus(resp, data)
        return data
    }

    private static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    private static func checkStatus(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        let body = String(data: data, encoding: .utf8) ?? ""
        throw GitHubError.http(status: http.statusCode, body: String(body.prefix(300)))
    }
}

// MARK: - kown:write → GitHub 提交

extension GitHubClient {
    /// 把一个 `kown:write` 提议提交到 GitHub。更新已有文件会先 GET 拿 sha + 旧内容(旧内容用于 diff)。
    /// 无论成功失败都返回一条 `AppliedWrite`(沿用本地 workspace 写入的归档结构,UI 复用同一套展示)。
    func commit(_ write: PendingWrite, owner: String, repo: String, branch: String) async -> AppliedWrite {
        let cleanRel = write.relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ \t\n"))
        guard !cleanRel.isEmpty, !cleanRel.contains("..") else {
            return AppliedWrite(relativePath: write.relativePath, action: .skipped,
                                success: false, error: "路径为空或含 ..,拒绝", newContent: write.content)
        }
        do {
            let existing = try await getFile(owner: owner, repo: repo, path: cleanRel, branch: branch)
            if let old = existing.content, old == write.content {
                return AppliedWrite(relativePath: cleanRel, action: .skipped, success: false,
                                    error: "内容与远端一致,无需提交", oldContent: old, newContent: write.content)
            }
            let msg = "\(existing.sha == nil ? "Create" : "Update") \(cleanRel) via Kown"
            let commit = try await putFile(owner: owner, repo: repo, path: cleanRel,
                                           content: write.content, message: msg, branch: branch, sha: existing.sha)
            return AppliedWrite(
                relativePath: cleanRel,
                action: existing.sha == nil ? .create : .update,
                success: true,
                oldContent: existing.content,
                newContent: write.content,
                remoteURL: commit.htmlURL
            )
        } catch {
            return AppliedWrite(relativePath: cleanRel, action: .update, success: false,
                                error: error.localizedDescription, newContent: write.content)
        }
    }

    /// 注入到 system prompt 的写入说明:告诉模型本会话已连到某 GitHub 仓库,改文件要用 kown:write 块。
    static func writeInstructions(repo: String, branch: String) -> String {
        """
        <github_workspace repo="\(repo)" branch="\(branch)">
        本会话已连接 GitHub 仓库 `\(repo)`(分支 `\(branch)`)。
        如果用户要求你创建 / 修改 / 重写文件,你 **必须** 输出下面格式的代码块,系统会自动提交到该仓库:

        ```kown:write <相对路径>
        <整个文件的完整新内容(不是 diff、不是片段)>
        ```

        规则:
        - 第一行必须是 ` ```kown:write ` 后跟一个空格再跟仓库内相对路径(不能有前导 `/`,不能用 `..`)。
        - 块里写**整个文件的新内容**,系统会读取远端旧版本算出改动行数后提交。
        - 多个文件 = 多个块。提交后会在聊天里显示每个文件的 +/- 行数与 commit 链接。
        - 只是讨论 / 回答问题时不要输出 kown:write 块。
        </github_workspace>
        """
    }
}

/// 一次发送的 GitHub 写入目标快照(owner/repo/branch/token)。
struct GitHubWriteTarget: Sendable {
    let owner: String
    let repo: String
    let branch: String
    let token: String

    var fullName: String { "\(owner)/\(repo)" }

    /// 从 "owner/repo" + 可选分支 + token 构造;缺 token 或仓库名不合法返回 nil。
    static func make(repoFullName: String?, branch: String?, token: String?) -> GitHubWriteTarget? {
        guard let repoFullName, let token, !token.isEmpty else { return nil }
        let parts = repoFullName.split(separator: "/").map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let b = (branch?.isEmpty == false) ? branch! : "main"
        return GitHubWriteTarget(owner: parts[0], repo: parts[1], branch: b, token: token)
    }
}
