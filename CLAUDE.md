# Kown 开发公约

跨平台 SwiftUI 应用(macOS + iOS),共享一份源码,分三个构建目标发布。本文件是仓库内权威约定,改动行为前先读这里。

## 项目结构

- **`Package.swift`(SwiftPM)是唯一源码真源**:`swift build` 用它跨平台编译共享源码 `Sources/Kown`。
- iOS / mac 各有一个 **xcodegen** 工程:`ios/project.yml`、`mac/project.yml`,其 `sources` 是 `type: group` 指向 `../Sources/Kown`。
- 三个目标(SwiftPM / iOS / mac)**共享同一份 `Sources/Kown`**,平台差异用 `#if os(macOS)` / `#if os(iOS)` 区分。
- Sparkle 仅 macOS 链接(`.when(platforms: [.macOS])`),iOS 不链接。

## 提交规约

- Conventional Commits,中文描述:`feat:` `fix(scope):` `chore:` `release:` `ci:` 等。
- **一个功能/一处逻辑改动 = 一个提交**,不要把无关改动堆进一个 commit。
- 每条 commit message 结尾加一行:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  ```
- **只有用户明确要求时才 commit / push**。

## 新增/移动源文件铁律 ⚠️

SwiftPM 自动 glob `Sources/Kown`,但 **Xcode 工程是显式文件表**。在 `Sources/Kown` 下新增、删除或移动 `.swift` 文件后,**必须重新生成两个 Xcode 工程并提交 pbxproj**:

```bash
cd ios && xcodegen generate
cd mac && xcodegen generate
git add ios/Kown.xcodeproj/project.pbxproj mac/Kown.xcodeproj/project.pbxproj
```

否则 iOS/mac 工程会报 `cannot find 'X' in scope`,且 CI 用的是 **committed 的 xcodeproj(不跑 xcodegen)**,本地不补就会发版失败。

## 构建验证

- 任何代码改动至少跑 `swift build`。
- **发版前三个目标都要过**:
  ```bash
  swift build
  cd ios && xcodebuild -project Kown.xcodeproj -scheme Kown \
      -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
  cd mac && xcodebuild -project Kown.xcodeproj -scheme Kown \
      -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
  ```

## 更新日志(CHANGELOG)铁律 ⚠️

`Sources/Kown/Resources/CHANGELOG.md` 跟 app 一起打包,`ChangelogService` 按 `CFBundleShortVersionString`(= `MARKETING_VERSION`)判断「有没有没看过的更新」并弹 What's New。

- **每次发版前**,必须在 `CHANGELOG.md` **顶部**(`# 更新日志` 之下)新增该版本条目,**最新版本在最上面**。
- 条目格式与现有保持一致:
  ```markdown
  ## <version> — <YYYY-MM-DD>
  ### 新增 / 改进 / 修复 / 修复(严重) / 维护
  - **一句话标题** — 给用户看的说明:做了什么、解决什么问题、带来什么好处
  ```
- 版本号用当次发版的版本(历史上以 **mac 版本**为时间线主线)。漏写会导致用户升级后 What's New 弹出空/旧内容。
- **顺序**:先写好 CHANGELOG 并 commit,再 bump 版本号、打 tag(见下)。

## 发版 / push 规则

通用:**先 `git push origin main`,再 push tag**(保证 tag 指向的 commit 已在远端)。版本递增:多个新功能 → minor,纯 bugfix → patch。版本号由 **tag 名**决定,build 号 = **git 提交数**(单调递增,每次上传唯一)。**打 tag 前先确认 CHANGELOG.md 已补好当次版本条目**(见上)。

**iOS 与 mac 版本号必须保持一致** ⚠️:同一份代码、同一份 `CHANGELOG.md`(条目以这个统一号为标题)。`ChangelogService` 按 `CFBundleShortVersionString` 匹配 What's New,两端版本号若不一致,版本号落后的那端会匹配不到 CHANGELOG 条目 → What's New 弹空。所以每次发版**两端用同一个 `<version>`**,同时打 `v<version>`(mac)和 `ios-v<version>`(iOS)两个 tag。

### iOS → TestFlight

- 触发:push tag `ios-v<version>` → `.github/workflows/ios-release.yml`。
- 例:`ios-v0.4.0` ⇒ `MARKETING_VERSION=0.4.0`。
- 步骤:
  1. 改 `ios/project.yml` 的 `MARKETING_VERSION`
  2. `cd ios && xcodegen generate`
  3. commit → `git push origin main`
  4. `git tag -a ios-v<version> -m "iOS <version>"` → `git push origin ios-v<version>`

### mac → Sparkle 自动更新

- 触发:push tag `v<version>`(`v*.*.*`)→ `.github/workflows/release.yml`。
- 步骤:
  1. 改 `mac/project.yml` 的 `MARKETING_VERSION`
  2. `cd mac && xcodegen generate`
  3. commit → `git push origin main`
  4. `git tag -a v<version> -m "mac <version>"` → `git push origin v<version>`
- **版本号铁律**:`mac/Info.plist` 的 `CFBundleVersion` 必须是 `$(CURRENT_PROJECT_VERSION)`、`CFBundleShortVersionString` 是 `$(MARKETING_VERSION)`。硬编码成 `1` 会让 Sparkle 陷入**无限更新循环**(0.6.13 修过)。
- **禁止 ad-hoc 签名**:发版包要分发给他人,必须走 **Developer ID + notarize + staple**(`scripts/release.sh`,带 `IDENTITY` / `NOTARY_PROFILE=kown-notarize`)。ad-hoc 会触发别人 Mac 的 Gatekeeper 拦截。
- **禁止 `Bundle.module`**:macOS App Translocation(带 quarantine 的 app)下 `Bundle.module` 静态初始化 `fatalError` → 启动即崩(0.5.6 全员翻车)。资源直接平铺进 `.app/Contents/Resources/`,用 `Bundle.main` 读,找不到静默返回 nil。验证必须带 quarantine 跑(`xattr -w com.apple.quarantine ...` 后 `open`)。
- 更新源仓库:公开仓库 `macuhy/kown-mac`(`appcast.xml`);源码私有仓库 `macuhy/kown`。Sparkle 打包细节见 `scripts/release.sh`。

## 检查发版状态

```bash
gh run list --limit 5        # 看触发的 workflow
gh run watch <run-id>        # 跟踪到完成/失败
```
