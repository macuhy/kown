# Kown — macOS LLM Council

并发请求多家大模型厂商,流式并排展示回答。Swift 6 + SwiftUI 原生 macOS 应用。

## 运行

### macOS

```bash
swift run Kown
```

或在 Xcode 16 中打开 `Package.swift` 直接 ⌘R。

### iOS

```bash
open -a Xcode Package.swift
# 在 Xcode 顶部 destination 选 iPhone 17 Pro(或任意 iOS 17+ 模拟器)→ ⌘R
```

iOS 端差异:
- 没有 CLI provider(`.cliCommand` — iOS 沙箱不能起子进程,已自动隐藏)
- Council 模式 panel 改成**垂直堆叠**(iPhone 屏不够并排)
- Compare 模式 panel 改成**横向滑动(swipe)的 pager**,两家答复一屏一家
- 文件 / 图片附件走 SwiftUI `.fileImporter`(底部上滑面板)
- 会话 / 日志存到 App Documents 沙箱(`Documents/.kown/`)而不是 `~/.kown/`;API Key 由 `KeychainStore` secret store facade 管理,当前默认 JSON 后端也只留本机,不随 iCloud Drive 同步

## 配置

- 点击右上角齿轮打开「厂商配置」
- 默认已种入 4 家(OpenAI / Anthropic / Gemini / DeepSeek),全部未启用
- 每家可改:`Base URL`、`Model`、`API Key`,改完点「保存 Key」(只对 Key 字段需要;其他字段失焦或回车即保存)
- 打开 Toggle 启用,关掉 sheet 回到主界面

## 使用

- 顶部输入 Prompt
- 点「并发发送」或 ⌘↩
- 启用的厂商**同时**开始流式输出,每列独立成功/失败
- 流式中可点「取消」中止全部

## 支持的厂商类型

- `openAICompatible`:OpenAI / DeepSeek / Kimi / 通义 / 智谱 等所有兼容 `/chat/completions` SSE 协议的服务
- `anthropic`:Claude(`/messages` + `x-api-key`)
- `gemini`:Google Gemini(`:streamGenerateContent?alt=sse`)

要接入新的国内厂商,通常用「添加 OpenAI 兼容」即可,只改 Base URL 和 model 名。

## 安全

- API Key 通过 `KeychainStore` secret store facade 管理;当前默认后端是本机-only JSON(`apikeys.json`,权限 0600),不随 iCloud Drive 同步
- 设置 ▸ 密钥存储 可显式复制并启用 Keychain Services / `SecurityKeychainBackend`;迁移会回读校验,不会删除原 JSON
- 非密钥配置存 UserDefaults(key: `kown.providers.v1`)

## 发版打包(DMG)

一键脚本 `scripts/release.sh`,处理 build → sign → (可选) notarize → DMG 全流程。

### 快速试一下(ad-hoc 签名,自用或小圈子分发)

```bash
./scripts/release.sh 0.3.0
```

产物:`dist/Kown-0.3.0.dmg`。其他人首次打开会被 Gatekeeper 拦"无法验证开发者",可以右键 → 打开 → 同意,或一次性命令:

```bash
xattr -dr com.apple.quarantine /Applications/Kown.app
```

### 正式分发(Developer ID + notarize,Gatekeeper 不拦)

**一次性 setup**(签所有未来的 app 都通用):

1. 在 [developer.apple.com](https://developer.apple.com/account/resources/certificates) 创建 **Developer ID Application** 证书,装进登录钥匙串。需要 $99/年 Apple Developer Program 成员。证书有效期 5 年。

2. 在 [appleid.apple.com](https://appleid.apple.com/account/manage) → Sign-In and Security → App-Specific Passwords 生成一个 app-specific password。

3. 把凭据存进本地 keychain profile(永久,所有 app 共用):

   ```bash
   xcrun notarytool store-credentials kown-notarize \
       --apple-id you@example.com \
       --team-id ABCD123456 \
       --password xxxx-xxxx-xxxx-xxxx
   ```

**每次发版**:

```bash
IDENTITY="Developer ID Application: 你的名字 (ABCD123456)" \
  NOTARY_PROFILE=kown-notarize \
  ./scripts/release.sh 0.4.0
```

脚本会:hardened runtime 签 .app → ditto 成 zip 提交 notarize 等候完成 → staple 票据 → hdiutil 做 DMG → 给 DMG 也签名 + notarize + staple。整个流程一般 3–8 分钟(notarize 排队时间居多)。

产物 DMG 别人下载双击直接挂载、拖到 Applications,无任何警告。

### 脚本环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `IDENTITY` | `-` (ad-hoc) | codesign `--sign` 参数。完整形式如 `"Developer ID Application: Foo Bar (ABCD123456)"` |
| `NOTARY_PROFILE` | 空 | `xcrun notarytool` 的 keychain profile 名;空 = 不 notarize |

不带 `IDENTITY` 就是 ad-hoc;带了 `IDENTITY` 但不带 `NOTARY_PROFILE` 是签名但不 notarize(签名身份能验证但 Gatekeeper 仍会拦,因为缺 notarize 票据)。

### CI 集成

`scripts/release.sh` 接受版本号参数,无交互,适合塞进 GitHub Actions / 本地 git tag hook。证书和 keychain profile 在 CI 上可以用 `security import` + `security create-keychain` 部署。
