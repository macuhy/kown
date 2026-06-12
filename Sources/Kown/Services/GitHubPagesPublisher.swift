import Foundation
import CryptoKit

/// Artifact 一键发布到 GitHub Pages。
///
/// 设计:
/// - **专用仓库 `kown-pages`**(不是 `<username>.github.io`):后者一个账号只有一个、
///   且很多人已用作个人主页,新建/复用都可能撞车;专用仓库实现成本最低、互不干扰。
/// - 发布 = `putFile` 把自包含 HTML 写到 `pages/<slug>.html`(复用 `GitHubClient` 的 Contents API,
///   已有文件自动带 sha 覆盖更新)。
/// - 仓库不存在时自动创建(**公开**,Pages 需要公开仓库才能免费托管),并尽力调 Pages API 开启站点;
///   API 开不了(权限/计划限制)时不报错,提示用户去仓库设置手动开一次。
/// - 页面最终地址:`https://<username>.github.io/kown-pages/pages/<slug>.html`。
struct GitHubPagesPublisher: Sendable {
    let token: String

    /// 发布专用仓库名。
    static let repoName = "kown-pages"

    private static let api = "https://api.github.com"

    /// 一次发布的结果。
    struct Result: Sendable {
        /// 页面最终地址(Pages 站点 URL,不是 commit 地址)。
        let pageURL: String
        /// 是否覆盖了已存在的文件(更新)而非新建。
        let isUpdate: Bool
        /// 本次是否(尝试)新开启了 Pages 站点 —— true 时提示用户首次生效要等几分钟。
        let pagesJustEnabled: Bool
        /// Pages 开启失败(API 不允许等),需要用户去仓库设置手动开一次。
        let needsManualPagesSetup: Bool
    }

    // MARK: - 发布主流程

    /// 把自包含 HTML 发布到 `kown-pages` 仓库的 `pages/<slug>.html`。
    /// 步骤:取用户名 → 确保仓库存在(必要时创建) → 写文件 → 尽力开启 Pages。
    func publish(slug: String, html: String) async throws -> Result {
        let login = try await currentUserLogin()
        let (created, branch) = try await ensureRepo(owner: login)

        let client = GitHubClient(token: token)
        let path = "pages/\(slug).html"
        // 已有文件需带旧 sha 才能覆盖(Contents API 约定)。
        let existing = try await client.getFile(owner: login, repo: Self.repoName, path: path, branch: branch)
        let isUpdate = existing.sha != nil
        let message = isUpdate ? "更新页面 \(slug)(via Kown)" : "发布页面 \(slug)(via Kown)"
        _ = try await client.putFile(owner: login, repo: Self.repoName, path: path,
                                     content: html, message: message, branch: branch, sha: existing.sha)

        // 尽力开启 Pages:已开启 → 什么都不做;开不了 → 不阻塞发布,提示手动设置。
        var justEnabled = false
        var needsManual = false
        if try await pagesEnabled(owner: login) == false {
            do {
                try await enablePages(owner: login, branch: branch)
                justEnabled = true
            } catch {
                needsManual = true
            }
        } else if created {
            // 新建仓库 + Pages 已存在不太可能,但保险起见仍按「刚开启」提示等待。
            justEnabled = true
        }

        return Result(
            pageURL: "https://\(login).github.io/\(Self.repoName)/pages/\(slug).html",
            isUpdate: isUpdate,
            pagesJustEnabled: justEnabled,
            needsManualPagesSetup: needsManual
        )
    }

    // MARK: - slug

    /// 默认 slug:标题拉丁化(中文 → 拼音)后转小写连字符;拉丁化后没剩下可用字符时退化为短 hash。
    static func defaultSlug(title: String?, fallbackSeed: String) -> String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let mutable = NSMutableString(string: title)
            CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
            CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
            let latin = sanitizeSlug(mutable as String)
            if !latin.isEmpty { return latin }
        }
        return "artifact-\(shortHash(fallbackSeed))"
    }

    /// 用户输入的 slug 清洗:只留小写字母 / 数字 / 连字符,连续分隔符折叠,最长 60。
    static func sanitizeSlug(_ raw: String) -> String {
        var out = ""
        var lastWasDash = true  // 开头不要连字符
        for scalar in raw.lowercased().unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
            if out.count >= 60 { break }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// 稳定短 hash(SHA256 前 8 位十六进制)— 不用 hashValue,它每次启动都会变。
    static func shortHash(_ seed: String) -> String {
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(8).lowercased()
    }

    // MARK: - GitHub API（Pages 相关，GitHubClient 没有的部分）

    /// 当前 token 对应的用户名(login)。GET /user
    func currentUserLogin() async throws -> String {
        let (data, resp) = try await URLSession.shared.data(for: request(path: "/user"))
        try check(resp, data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = json["login"] as? String, !login.isEmpty else {
            throw GitHubError.decoding("user 响应缺 login")
        }
        return login
    }

    /// 确保 `kown-pages` 仓库存在;不存在则创建(公开 + auto_init,Pages 需要分支已存在)。
    /// 返回 (是否本次新建, 默认分支)。
    private func ensureRepo(owner: String) async throws -> (created: Bool, branch: String) {
        let (data, resp) = try await URLSession.shared.data(
            for: request(path: "/repos/\(owner)/\(Self.repoName)"))
        if let http = resp as? HTTPURLResponse, http.statusCode == 404 {
            let branch = try await createRepo()
            return (true, branch)
        }
        try check(resp, data)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (false, (json["default_branch"] as? String) ?? "main")
    }

    /// 创建公开仓库 `kown-pages`。POST /user/repos。返回默认分支。
    private func createRepo() async throws -> String {
        var req = request(path: "/user/repos")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": Self.repoName,
            "description": "Kown 发布的 Artifact 页面",
            "private": false,
            "auto_init": true,   // 先有分支,Pages 才能指到它
            "has_issues": false,
            "has_wiki": false,
            "has_projects": false
        ] as [String: Any])
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (json["default_branch"] as? String) ?? "main"
    }

    /// Pages 站点是否已开启。GET /repos/{owner}/{repo}/pages,404 = 未开启。
    private func pagesEnabled(owner: String) async throws -> Bool {
        let (data, resp) = try await URLSession.shared.data(
            for: request(path: "/repos/\(owner)/\(Self.repoName)/pages"))
        if let http = resp as? HTTPURLResponse, http.statusCode == 404 { return false }
        try check(resp, data)
        return true
    }

    /// 开启 Pages 站点(源 = 默认分支根目录)。POST /repos/{owner}/{repo}/pages。
    /// 409 = 已开启(并发/缓存),视为成功。
    private func enablePages(owner: String, branch: String) async throws {
        var req = request(path: "/repos/\(owner)/\(Self.repoName)/pages")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "source": ["branch": branch, "path": "/"]
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 409 { return }
        try check(resp, data)
    }

    // MARK: - 请求 helpers（与 GitHubClient 同款头,但那边是 private 取不到）

    private func request(path: String) -> URLRequest {
        var req = URLRequest(url: URL(string: Self.api + path)!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("Kown", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        return req
    }

    private func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        let body = String(data: data, encoding: .utf8) ?? ""
        throw GitHubError.http(status: http.statusCode, body: String(body.prefix(300)))
    }

    /// 把底层错误翻译成给用户看的中文提示。
    static func friendlyMessage(for error: Error) -> String {
        if let gh = error as? GitHubError {
            switch gh {
            case .http(let status, _):
                switch status {
                case 401: return "GitHub 授权已失效,请到 设置 → GitHub 重新连接"
                case 403: return "没有权限操作该仓库(token 权限不足或触发了限流),稍后重试或重新连接 GitHub"
                case 404: return "仓库不存在或无权访问,请检查 GitHub 账号状态"
                case 422: return "GitHub 拒绝了请求(参数无效),请换一个文件名再试"
                default:  return gh.localizedDescription
                }
            default:
                return gh.localizedDescription
            }
        }
        if (error as? URLError) != nil {
            return "网络请求失败,请检查网络后重试"
        }
        return error.localizedDescription
    }
}

// MARK: - 已发布 slug 记忆

/// 记住每个 artifact 上次发布用的 slug(UserDefaults),
/// 再次发布同一 artifact 时默认覆盖同一页面(更新)而不是另开新页。
enum ArtifactPublishMemory {
    private static let defaultsKey = "kown.artifactPublishedSlugs"

    /// 该 artifact 上次发布的 slug;没发布过返回 nil。
    static func slug(for artifactKey: String) -> String? {
        let map = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]
        return map?[artifactKey]
    }

    /// 记录该 artifact 本次发布的 slug。
    static func remember(slug: String, for artifactKey: String) {
        var map = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        map[artifactKey] = slug
        UserDefaults.standard.set(map, forKey: defaultsKey)
    }
}
