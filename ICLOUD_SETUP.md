# iCloud 同步 — 配置与发布手册

本应用通过 iCloud Drive Ubiquity Container 在多端同步数据(会话 / Provider 配置 / Web Search 配置 / API Key)。本文档记录完整的实现、配置、发布与故障排查。

## 1. 同步范围

| 数据 | 位置 | 是否同步 |
|---|---|---|
| 会话(turns + Debate rounds) | `[syncedDataDir]/conversations/*.json` | ✅ |
| Provider 配置(Base URL / model / temperature) | `[syncedDataDir]/config.json` | ✅ |
| Web Search 配置(Firecrawl) | `[syncedDataDir]/web_search.json` | ✅ |
| **API Key**(各 Provider + Firecrawl) | `[syncedDataDir]/apikeys.json` | ✅ |
| Debate 轮数 / Web Search 开关 / systemPrompt | UserDefaults | ❌(每台独立) |
| 当前会话选中 ID | 内存 | ❌ |

- `syncedDataDir` 同步开启 + 容器可用时 = iCloud Documents 容器内的 `.kown/`;否则 = 本地 `~/.kown`(macOS)/ App Documents/.kown(iOS)
- 容器对 Files / iCloud Drive 列表 **不可见**(`NSUbiquitousContainerIsDocumentScopePublic=false`),API Key 不会出现在用户的 iCloud Drive 中

### 安全说明

- iCloud Drive 在 Apple 服务器侧 at-rest 加密(TLS 传输),**不是端到端加密** — Apple 持有 key
- 同一 Apple ID 登录的设备 + 安装本应用才能读到容器内数据
- 想要真端到端加密 API Key 同步,可后续把 `KeychainStore` 重写为真 Keychain Services + `kSecAttrSynchronizable=true`

---

## 2. 代码架构

### 关键文件

```
Sources/Kown/
├── Services/
│   ├── ICloudSync.swift               # 单例 @Observable @MainActor,管理同步状态
│   ├── ConversationStore.swift        # 走 Platform.syncedDataDir
│   ├── KeychainStore.swift            # 走 Platform.syncedDataDir(API Key 也同步)
│   └── ConversationSummarizer.swift   # @MainActor
├── Models/
│   ├── Provider.swift                 # ProviderConfigStore: syncedDataDir
│   └── WebSearch.swift                # WebSearchConfigStore + WebSearchKey: syncedDataDir
├── Platform.swift                     # localDataDir / syncedDataDir 路由
├── ViewModels/
│   └── AppViewModel.swift             # setICloudSyncEnabled(_:),iCloudSync 引用
└── Views/
    ├── ICloudSyncSettingsView.swift   # Settings → iCloud 同步 tab
    └── SettingsView.swift             # 添加第三个 tab
```

### 同步流程

1. **启动**:`ICloudSync.shared` 后台探测 `FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.xiaobo.kown")`
2. **开关切换**:`AppViewModel.setICloudSyncEnabled(true)`:
   - `migrateLocalToCloud()`(`overwrite: false`,远端为准)
   - 切换 `Platform.syncedDataDir` 路由
   - 重新 `ConversationStore.loadAll() / ProviderConfigStore.load() / WebSearchConfigStore.load()`
3. **运行时**:所有 Store 通过 `Platform.syncedDataDir` 取目录,系统自动后台同步
4. **账号切换**:监听 `NSUbiquityIdentityDidChange`,自动 `refreshContainerURL()`
5. **关同步**:`mirrorCloudToLocal()`(`overwrite: true`,云端为准)→ 切回本地

### Container Identifier

代码里写死:**`iCloud.com.xiaobo.kown`**(`ICloudSync.containerIdentifier`)

如需更换,三处需要保持一致:
1. `Sources/Kown/Services/ICloudSync.swift` → `containerIdentifier` 常量
2. `dist/Kown.entitlements`(macOS)→ 三个 `com.apple.developer.*` 数组
3. `ios/project.yml` → `NSUbiquitousContainers` key + `entitlements.properties` 三个数组(改完后 `xcodegen generate`)

---

## 3. 一次性配置 — Apple Developer Console

### 3.1 iCloud Container

**https://developer.apple.com/account/resources/identifiers/list?filter=cloudContainer**

- 右上角 Team 必须是 **`4257SFGRFK`**(付费 Developer Program)
- 没有的话:`+` → Description: `Kown` → Identifier: **`iCloud.com.xiaobo.kown`**(必须一字不差)

### 3.2 App ID 关联 iCloud Container

**https://developer.apple.com/account/resources/identifiers/list?filter=bundleId**

- Bundle ID **`com.xiaobo.kown`**(没有则 `+` 新建)
- 点进 App ID → Capabilities 列表 → 找 **iCloud** → ✅ 勾上
- 旁边的 **`Configure`** / **`Edit`** 按钮 → 弹出 Container 列表 → 勾上 **`iCloud.com.xiaobo.kown`** → Save
- 回到 App ID 页面 → 底部 **Save**

> **这一步是 90% 的人卡死的地方**:Container 已建好但 App ID 没勾选关联,导致 amfid 拒绝带 iCloud entitlement 的 app 启动(error 163 "Launchd job spawn failed")。

### 3.3 签名证书(macOS)

需要 **`Developer ID Application`** 类型证书,Team `4257SFGRFK`,**且私钥必须在本机 Keychain**。

确认方式:
```bash
security find-identity -p codesigning -v
```
看到 `Developer ID Application: bo xiao (4257SFGRFK)` 才算齐。

若 cert 在 Keychain 但 `find-identity` 看不到 → **私钥不在本机**。两条路:
- A. 从原始 Mac Keychain Access 同时选中证书 + 私钥 → Export 成 `.p12` → 拷到本机双击
- B. Developer Console **Revoke** 当前证书 → Keychain Access → Certificate Assistant → **Request a Certificate** → **Saved to disk**(关键)→ 上传新 CSR → 下载 cert → 双击装入

### 3.4 公证凭据(Apple ID 应用专属密码)

1. **https://account.apple.com/account/manage** → Sign-In and Security → App-Specific Passwords → Generate
2. 拿到 `xxxx-xxxx-xxxx-xxxx` 格式密码
3. 存进 Keychain:
   ```bash
   xcrun notarytool store-credentials kown-notarize \
       --apple-id "490429806@qq.com" \
       --team-id "4257SFGRFK" \
       --password "xxxx-xxxx-xxxx-xxxx"
   ```
   存好后看到 `Success. Credentials validated.`,以后再发布不会再要密码。

---

## 4. 一次性配置 — 项目文件

### macOS entitlements

**`dist/Kown.entitlements`**(正式发布用):
```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array><string>iCloud.com.xiaobo.kown</string></array>
<key>com.apple.developer.icloud-services</key>
<array><string>CloudDocuments</string></array>
<key>com.apple.developer.ubiquity-container-identifiers</key>
<array><string>iCloud.com.xiaobo.kown</string></array>
```

**`dist/Kown-local.entitlements`**(本地 ad-hoc 测试用,无 iCloud):仅保留 `app-sandbox=false / network.client / files.user-selected.read-write`。
ad-hoc 签名 + iCloud entitlements 会被 launchd 拒(error 163),所以本地无证书测试时切到这份。

### iOS

**`ios/project.yml`** 关键段(已配齐):
```yaml
info:
  properties:
    NSUbiquitousContainers:
      iCloud.com.xiaobo.kown:
        NSUbiquitousContainerIsDocumentScopePublic: false   # 对 Files app 隐藏
        NSUbiquitousContainerName: Kown
        NSUbiquitousContainerSupportedFolderLevels: Any
entitlements:
  path: Kown.entitlements
  properties:
    com.apple.developer.icloud-container-identifiers:
      - iCloud.com.xiaobo.kown
    com.apple.developer.icloud-services:
      - CloudDocuments
    com.apple.developer.ubiquity-container-identifiers:
      - iCloud.com.xiaobo.kown
```

改完 `project.yml` 跑一次:
```bash
cd ios && xcodegen generate
```

---

## 5. 发布流程(macOS)

### 5.1 关键前置:Developer ID Provisioning Profile

> **⚠️ 关键坑**:Developer ID + iCloud entitlements 必须在 .app 里**嵌入 provisioning profile**(`Contents/embedded.provisionprofile`)。不嵌入,本机能跑(你的 Xcode profile 目录有 fallback),**别人 Mac 启动直接报"应用程序无法打开"** — amfid 找不到 entitlement 授权链就拒。
>
> 仅 macOS 需要手动嵌入;iOS Xcode 自动管理,不用操心。

一次性配置:
1. **https://developer.apple.com/account/resources/profiles/add**
2. 选 **Distribution → Developer ID**(注意是 Distribution 那组,不是 Development)
3. **Profile Type**:`Direct Distribution`(关键 — `ProvisionsAllDevices=true`,所有 Mac 都能用)
4. **App ID**:`com.xiaobo.kown`
5. **Certificate**:选有本机私钥的那张 Developer ID Application
6. **Profile Name**:`Kown Developer ID`
7. Generate → Download `.provisionprofile` → 双击装入
8. 装入路径:`~/Library/Developer/Xcode/UserData/Provisioning Profiles/<UUID>.provisionprofile`

验证 profile 类型对:
```bash
PROFILE="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/<UUID>.provisionprofile"
security cms -D -i "$PROFILE" | plutil -extract ProvisionsAllDevices raw -
# 必须输出 true
```

`scripts/release.sh` 里 `PROFILE_UUID` 写死了 Kown 的 UUID — 换项目时改这一行即可。

### 5.2 发布命令

凭据都存进 Keychain 后,一条命令搞定:

```bash
IDENTITY="Developer ID Application: bo xiao (4257SFGRFK)" \
  NOTARY_PROFILE=kown-notarize \
  ./scripts/release.sh 0.4.3
```

脚本自动做:
1. `swift build -c release`
2. 拷贝 binary 到 `dist/Kown.app/Contents/MacOS/Kown`
3. 写入 CFBundleShortVersionString + CFBundleVersion (git commit count)
4. **嵌入 `Contents/embedded.provisionprofile`**(`Kown Developer ID` profile)← 5.1 装好后这步才能成功
5. codesign 用 Developer ID + 完整 entitlements(含 iCloud)
6. 提交 Apple 公证 → 等待 → staple 票据
7. 打 DMG + 公证 DMG + staple

产物:
- `dist/Kown.app`(可直接拖到 /Applications)
- `dist/Kown-0.4.3.dmg`(可分发)

装到本机:
```bash
kill $(pgrep -f "/Applications/Kown.app/Contents/MacOS/Kown") 2>/dev/null
rm -rf /Applications/Kown.app
cp -R dist/Kown.app /Applications/
xattr -dr com.apple.quarantine /Applications/Kown.app
open /Applications/Kown.app
```

### 5.3 macOS 26+ 公证凭据特殊处理

macOS 26 起 `notarytool` 在不指定 `--keychain` 时找不到默认 keychain 里的 profile。`store-credentials` 和 submit 都要显式带:
```bash
xcrun notarytool store-credentials kown-notarize \
    --apple-id "..." --team-id "..." --password "..." \
    --keychain "$HOME/Library/Keychains/login.keychain-db"

xcrun notarytool submit Kown.zip \
    --keychain-profile kown-notarize \
    --keychain "$HOME/Library/Keychains/login.keychain-db" --wait
```
`scripts/release.sh` 已经加了这个参数。

---

## 6. 发布流程(iOS)

iOS 走 Xcode 自动签名,不用 release.sh,也不用手动嵌 profile(**Xcode 自动嵌入到 .app**):

1. `cd ios && xcodegen generate`(如果改了 project.yml 或加了新 .swift 文件)
2. `open ios/Kown.xcodeproj`
3. Target → **Signing & Capabilities**
4. Team 下拉选 **`bo xiao (4257SFGRFK)`**(不是 Personal/`QV55WUF9MA`)
5. 这一页确认 **iCloud** capability 已出现(没出现就点 `+ Capability` → 添加 iCloud → 勾上 `iCloud Documents` → Containers 加 `iCloud.com.xiaobo.kown`)
6. Xcode 自动:fetch 带 iCloud 的 development profile + 嵌入 entitlement + 嵌入 profile
7. **⌘R** 跑模拟器或真机

> **iOS 特有**:Xcode 自动嵌入的是 **macOS App Development profile**,只允许 Team 注册的设备运行 — 装在朋友手机上需要走 TestFlight / App Store Connect 分发(还要苹果审核)。本机自己调试用 ⌘R 就够。

模拟器测试 iCloud:模拟器 → 设置 → Apple ID 登录 → iCloud Drive 打开。真机更稳。

---

## 7. 踩坑实录(2026-05-25 ~ 2026-05-26,iOS / macOS 区分)

> 这一节是给**其它项目**复用的经验。每条问题标 **[macOS]** / **[iOS]** / **[共通]**。

### 7.1 [macOS] Developer ID + iCloud 必须嵌入 embedded.provisionprofile

**现象**:本机能跑(包括 release build + 公证 + staple 全套),发给别人 → "应用程序 Kown 无法打开" + Finder 笑脸图标(LaunchServices 深度拒绝)。

**根因**:`com.apple.developer.icloud-*` 这类受限 entitlement,amfid 启动校验时需要 profile 证明授权。本机能跑是因为 `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` 里有 fallback;别人 Mac 没你这份 profile → 拒。

**修法**:codesign 前把 profile 拷到 `${APP_BUNDLE}/Contents/embedded.provisionprofile`,然后再签名(profile 是签名 input 之一,顺序不能反)。

**release.sh 关键改动**:
```bash
PROFILE_UUID="<your-profile-uuid>"
PROFILE_SRC="${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles/${PROFILE_UUID}.provisionprofile"
cp -f "${PROFILE_SRC}" "${APP_BUNDLE}/Contents/embedded.provisionprofile"
# 然后才 codesign --force --sign ... --entitlements ... "${APP_BUNDLE}"
```

**注意**:profile 类型必须是 **Distribution → Developer ID → Direct Distribution**,验证:
```bash
security cms -D -i "$PROFILE" | plutil -extract ProvisionsAllDevices raw -
# 必须 true
```

iOS 不存在这个问题:Xcode 自动 fetch profile + 自动嵌入,不用人工管。

---

### 7.2 [macOS] codesign 报 "unable to build chain to self-signed root" / `errSecInternalComponent`

**现象**:`security find-identity` 显示 Developer ID 身份有效,`security verify-cert` 也说 trusted,但 `codesign --sign "Developer ID Application: ..."` 一调就崩。

**根因(我们遇到的)**:用户 Keychain 里有错误的 trust override。具体两条:
1. **`mitmproxy` 证书被设成 "Trust as Root"** — 中间人代理工具,一旦设为 root 会拦截所有 TLS chain evaluation,把 Apple PKI 的 Developer ID 验证也搅乱
2. **leaf 证书(Developer ID Application 那张)自己被错设成 "Trust as Root"** — 系统认为 leaf 就是 root,chain evaluation 死循环

**诊断**:
```bash
security dump-trust-settings    # 看 user-level overrides
security dump-trust-settings -d # 看 admin-level overrides
```
看到任何 `Apple Development` / `Developer ID` / 中间人代理证书在里面,就有嫌疑。

**修法**(导出证书后用文件路径 remove):
```bash
security find-certificate -c "mitmproxy" -p > /tmp/cert.pem
security remove-trusted-cert /tmp/cert.pem
# 同样处理 leaf 证书
security find-certificate -c "Developer ID Application: <你的名字>" -p > /tmp/leaf.pem
security remove-trusted-cert /tmp/leaf.pem
```

iOS 无此问题。

---

### 7.3 [共通] iCloud Documents 文件**默认按需下载**,接收设备读到的是空字节

**现象**:macOS 上同步开了,文件正常写到 iCloud;iPhone 这边 iCloud Drive 已经开启,但 app 看不到这些文件 / 看到空列表。

**根因**:iCloud Documents API 是"按需下载"模型 — 元数据自动同步,**文件字节不自动下载**。要 `FileManager.startDownloadingUbiquitousItem(at:)` 显式触发。否则 `Data(contentsOf:)` 读到的是 placeholder。

**修法**:Store 层 / iCloud 切换时遍历 ubiquity 容器,对 `URLUbiquitousItemDownloadingStatusKey != .current` 的文件触发下载:

```swift
guard let enumerator = FileManager.default.enumerator(
    at: directory,
    includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey, .isUbiquitousItemKey],
    options: [.skipsHiddenFiles]
) else { return }
for case let url as URL in enumerator {
    let v = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .isUbiquitousItemKey])
    guard v?.isUbiquitousItem == true else { continue }
    if v?.ubiquitousItemDownloadingStatus != .current {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }
}
// 等几秒让 iCloud 真把字节拉下来,再去读文件
try? await Task.sleep(for: .seconds(5))
```

UI 上加"立即刷新"按钮兜底:用户等不到自动同步时手动催。Kown 的 `ICloudSync.triggerDownloadsAndWait(in:)` 就是这套。

---

### 7.4 [共通] iCloud 切换时 UI 卡死

**现象**:点开关启用 iCloud 同步 → app 主线程冻几秒到几十秒(会话多时更严重),iOS 上 watchdog 可能直接杀进程。

**根因**:文件 migrate 用了 `Task { @MainActor in ... }` 但内部是同步 file I/O,没真正 yield → 仍在 main thread 跑。

**修法**:文件操作派到 `Task.detached` 后台 task:
```swift
return await Task.detached(priority: .utility) {
    Self.copyTree(from: local, to: cloudKown, overwrite: false)
}.value
```

`copyTree` 标 `nonisolated static` — 静态函数可以在任意线程跑。

---

### 7.5 [macOS] macOS 26 上 `notarytool` 默认 keychain 找不到 profile

**现象**:跑过 `notarytool store-credentials kown-notarize`,验证返回 "Success",但 `notarytool submit --keychain-profile kown-notarize` 报 `No Keychain password item found`。

**根因**:macOS 26 的 `notarytool` 在不指定 `--keychain` 时使用某个内部默认值,与 `store-credentials` 不指定时写入的位置不一致。

**修法**:两边都显式带 `--keychain`:
```bash
xcrun notarytool store-credentials kown-notarize \
    --apple-id ... --team-id ... --password ... \
    --keychain "$HOME/Library/Keychains/login.keychain-db"

xcrun notarytool submit ...zip \
    --keychain-profile kown-notarize \
    --keychain "$HOME/Library/Keychains/login.keychain-db" --wait
```

iOS 不走 notarytool(开发签名直接装真机),无此问题。

---

### 7.6 [macOS] 同一个 Apple ID 可能属于多个 Team,签名混淆

**现象**:Xcode Signing 里 Team 显示 `bo xiao`(单数),但实际签出来的 app TeamIdentifier 不是付费 Team。证书 CN 里写的 Team 和 OU 里的 Team **不一致**(我们遇到 CN = `QV55WUF9MA` 但 OU = `4257SFGRFK`)。

**关键认知**:
- CN(Common Name)是显示名,带历史包袱,可能写的是 Personal Team
- **OU(Organizational Unit)是真正的 Team ID**,codesign / amfid / iCloud Container 用的都是这个

**诊断**:
```bash
security find-certificate -c "Developer ID Application: <你的名字>" -p | \
  openssl x509 -noout -subject -nameopt multiline
```
看 `organizationalUnitName` 那行 = 真 Team ID。

**避坑**:iCloud Container / App ID / Provisioning Profile 都必须在 **OU 那个 Team** 下注册。Personal Team(免费,自动赋予的)不能签发 Developer ID 证书也不能开 iCloud Container,不要碰。

---

### 7.7 [macOS] 私钥不在本机 — `find-identity` 看不到证书

**现象**:`security find-certificate` 能看到 Developer ID 证书,但 `security find-identity -p codesigning -v` 看不到。

**根因**:.cer 是公钥证书,签名需要 cert + 私钥配对。私钥只在生成 CSR 那台 Mac 上。

**修法**(从原 Mac 迁移):
1. 原 Mac → Keychain Access → 找到证书 → **同时选证书 + 下面挂的私钥** → 右键 Export → `.p12` 格式 → 设密码
2. 拷到新 Mac → 双击 → 输密码 → 一起进 Keychain

**或撤销重发**:本机 Keychain Access → Certificate Assistant → **Request a Certificate from a CA → Saved to disk**(关键步骤,私钥才会留本机)→ 上传 CSR → 下载新 cert → 双击装入。

**Apple 限流警告**:同一 Team 短时间内连续撤销 + 重发会触发限流,Apple 给你短期(8 个月)而非正常 5 年的 Developer ID 证书。可以多发几张攒着,挑长期的用。

---

### 7.8 [macOS] 微信传 .dmg 触发 quarantine 二次确认对话框

**现象**:朋友通过微信收到 .dmg,装好 .app 首次启动弹 `"X" is an app created by the app **WeChat**. Are you sure...`。

**根因**:macOS quarantine 机制 — 任何"下载"应用都会给文件打 `com.apple.quarantine` 属性,首次启动 Gatekeeper 弹二次确认。`(WeChat)` 字段是 quarantine 属性里记录的 source app(送达者),不是说 app 由微信制作。

**避免**:
- AirDrop / U 盘 / `curl` 下载 — 不会打 quarantine
- 让接收方装完跑 `xattr -dr com.apple.quarantine /Applications/<App>.app` 一行抹掉
- 改用 `.pkg` 安装包(用 Developer ID Installer 证书签 + productsign + 公证)— 装出来的 app 不继承 quarantine

iOS 装应用必须通过 TestFlight / App Store,没有 quarantine 这套概念。

---

### 7.9 [macOS] App Translocation

**现象**:接收方双击 .dmg 后直接在挂载的 DMG 里点 .app → app 跑不起来或行为异常。

**根因**:quarantine + 没挪出原位 → macOS 把 app 跑在一个随机临时只读路径(GateKeeper Path Randomization),很多读资源 / 写文件操作会出错。

**修法**:**必须把 .app 从 DMG 拖到 `/Applications/`,然后 eject DMG,再启动**。这一步会清掉 quarantine 让 Translocation 不生效。

iOS 无此概念。

---

### 7.10 [共通] Xcode Archive / Run 每次都问 Team

**现象**:Xcode 选了 Team,但下一次 Archive / 开新工程 / 团队成员拉代码,又被问"选一个 Team"。

**根因**:`CODE_SIGN_STYLE: Automatic` 时 Xcode 需要 `DEVELOPMENT_TEAM` build setting,否则要求人工选。`xcodegen` 生成的项目默认不带这个。

**修法**:`project.yml` 的 `settings.base` 加:
```yaml
DEVELOPMENT_TEAM: 4257SFGRFK
```
然后 `xcodegen generate` 重新生成。Debug + Release 两个 configuration 都会自动带上。

Xcode 已经开着的话**杀掉 Xcode 重开**,否则会读到旧 build settings cache。验证 baked-in:
```bash
grep -c "DEVELOPMENT_TEAM = 4257SFGRFK" ios/Kown.xcodeproj/project.pbxproj  # 应该 = 2 (Debug+Release)
```

---

### 7.11 [iOS] TestFlight / App Store Connect 每次问 "Is your app using encryption?"

**现象**:每次往 App Store Connect 提交新 build,加密合规问卷弹出来要选一遍("Does your app use encryption?" / "Is your app exempt?")。

**根因**:Info.plist 没声明 `ITSAppUsesNonExemptEncryption`,Apple 默认认为需要走 export compliance 流程。

**修法**:`ios/project.yml` 的 `info.properties` 加:
```yaml
ITSAppUsesNonExemptEncryption: false
```
等价于声明 "**只用系统 HTTPS / TLS**,不算 non-exempt encryption,免提交合规文档"。

适用条件:
- 你只用 URLSession / WebKit 等系统 HTTPS — 算 exempt(免)
- 你**自己实现了**加密算法 / 用了非系统的加密库(libsodium 等)— 算 non-exempt,得申报

绝大多数 LLM / 网络客户端类 app 是前者,设 `false` 完全合规。

macOS 走 Developer ID 直接分发,无此问题(没有 App Store Connect 提交流程)。

---

### 7.12 [共通] 另一端的新数据(总结 / 新一轮回答 / Chair 输出)在本端看不到

**现象**:iPhone 上跑完一轮 Council,Chair / Summary 输出有了 + 已经同步到 iCloud;切到 Mac,Mac 上同一会话**只能看到老内容**,新增的 Chair 输出空白。

**根因**:`AppViewModel.conversations` 是启动那一刻 `ConversationStore.loadAll()` 读到的内存快照。运行期 iCloud 把新文件同步过来,**Mac 内存里没刷新**。

**更严重的次生 bug**:
- Mac 内存里是旧版本 → 用户在 Mac 上**继续提问同一会话** → Mac 用旧版本 + 新一轮 turn 构造新 conversation JSON → 整个文件 overwrite 回去 → **覆盖 iCloud 里 iPhone 写的 Chair 字段**
- iCloud 又把 Mac 的版本同步回 iPhone → iPhone 本地副本也变成 Mac 写的(数据丢失,只能靠 iCloud Drive 30 天版本历史 + NSFileVersion API 救)

**修法**:`KownApp` 监听 `@Environment(\.scenePhase)`,**只要 app 切到 `.active`**(开屏 / 切回前台 / 唤醒)就调一次 `refreshFromICloud()`:
```swift
.onChange(of: scenePhase) { _, newPhase in
    if newPhase == .active,
       viewModel.iCloudSync.isEnabled,
       viewModel.iCloudSync.isAvailable,
       !viewModel.iCloudMigrationInFlight {
        viewModel.refreshFromICloud()
    }
}
```
内存永远跟 iCloud 最新版对齐,继续提问基于最新,不再覆盖另一端的数据。

> 进阶:用 `NSMetadataQuery` 监听 ubiquity container 文件变更,主动 reload,比 scenePhase 更实时。但 NSMetadataQuery 实现复杂,scenePhase 兜底已经覆盖 95% 场景。

---

### 7.13 [共通] Firecrawl key(单值 Keychain key)首次启动看到"未设置"

**现象**:Firecrawl API key 保存过了,关掉 app 重开 → Settings 显示"未设置",每次都要重新填一次。Provider 自己的 API Key 没这个问题。

**根因**:用了**只在 init 时计算一次**的缓存属性:
```swift
private(set) var hasWebSearchKey: Bool = WebSearchKey.hasKey()
```
AppViewModel.init 跑的时刻 iCloud 容器还在异步后台探测没就绪,`syncedDataDir` fallback 到 local → 读本地 apikeys.json(可能空)→ false。1-2 秒后容器到位 → `syncedDataDir` 切换到 iCloud → 这个缓存值不再刷新,UI 一直显示"未设置"。

Provider 那边没问题是因为 `ProviderConfig` 列表每次渲染时都 query `KeychainStore.hasKey(id:)`,没缓存。Firecrawl 走的是**单值 fixed-UUID + cached Bool**,暴露了 race。

**修法**:
1. 新增 `refreshHasWebSearchKey()` 方法,重读 KeychainStore
2. 三处挂上:`setICloudSyncEnabled` 切换后、`refreshFromICloud` 刷新后、AppViewModel.init 延迟 2 秒的 cold-start task 里

通用教训:**任何"派生自 KeychainStore / ConversationStore / ProviderConfigStore 的缓存值",都得在 syncedDataDir 可能切换的时机(iCloud 容器就绪 / 用户切换 / 手动刷新)重算**。不要假设 init 时读到的值终生有效。

---

## 8. 当前状态(2026-05-26)

✅ 已完成:
- 代码全部实现,macOS / iOS build 双端通过
- Developer Console:Team `4257SFGRFK` 下注册了 `iCloud.com.xiaobo.kown` Container + App ID 关联
- Developer Console:Developer ID Application 证书已发并装入本机 Keychain(私钥配齐)
- Developer Console:`Kown Developer ID` provisioning profile(Direct Distribution,ProvisionsAllDevices)已发并装入本机
- 公证凭据 `kown-notarize` 已存入 Keychain(显式 `--keychain` 路径)
- `release.sh` 加了 embedded.provisionprofile 嵌入步骤
- `ios/project.yml` + `mac/project.yml` 都 baked `DEVELOPMENT_TEAM: 4257SFGRFK`(Archive 不再问 Team)
- `ios/project.yml` baked `ITSAppUsesNonExemptEncryption: false`(TestFlight 提交不再问加密)
- `KownApp` 监听 `scenePhase` 切到 active → 自动 `refreshFromICloud`(双向数据立即可见)
- `AppViewModel.refreshHasWebSearchKey()` 在 iCloud 状态变化时重算 Firecrawl key 缓存
- `dist/Kown-0.4.5.dmg` 已公证 + staple,**可发给任何 Mac 用户**
- iCloud 同步代码加了:`triggerDownloadsAndWait`、`refreshFromICloud`、UI 立即刷新按钮、cold-start 延迟 reload、迁移派到 detached task

---

## 9. 故障排查

### [macOS] 本机能跑,**别人 Mac 上启动报"应用程序无法打开"**(Finder 笑脸图标)
- 99% 是 .app 里**没嵌入 embedded.provisionprofile** — 见 §7.1
- 验证:`ls dist/Kown.app/Contents/embedded.provisionprofile`
- 修:`release.sh` 在 codesign 之前 `cp` profile 到 bundle 里

### [macOS] codesign 报 `errSecInternalComponent` / `unable to build chain to self-signed root`
- 见 §7.2,大概率 Keychain 里有错误的 trust override(mitmproxy / leaf cert)

### [macOS] 启动错误 163 / Launchd job spawn failed
- `spctl -a -vvv /Applications/Kown.app` 看 Gatekeeper 状态
- 若 `accepted, source=Notarized Developer ID` 但仍报 163 → **iCloud entitlement 被 amfid 拒**,99% 是 App ID 没关联 Container(§3.2)
- 第二可能:.app 里没嵌入 profile(§7.1)

### [macOS] Gatekeeper 报 "Unnotarized Developer ID"
- 公证脚本没跑成功,或 staple 没成功
- 重跑 `release.sh` 时确认 `NOTARY_PROFILE=kown-notarize` env var 有传入
- macOS 26+ 还要 `--keychain ~/Library/Keychains/login.keychain-db`(§5.3 / §7.5)

### [macOS] `security find-identity` 看不到 Developer ID Application
- 证书在 Keychain 但**私钥不在本机**(§7.7)
- 按 §3.3 路 B 撤销重发(本机生成 CSR 必须选 `Saved to disk`,私钥才会留下)

### [共通] App 启动但 Settings → iCloud 同步 状态为 "iCloud 不可用"
- 检查 `设置 → Apple ID → iCloud → iCloud Drive` 开着
- 检查 entitlements 嵌入正确:
  ```bash
  codesign -d --entitlements - /Applications/Kown.app | grep icloud
  ```
- 检查 Container 在 Developer Console 注册了且 App ID 关联了(§3.1 + §3.2)

### [iOS] iPhone 上 iCloud 显示已开启,但**看不到 macOS 上同步过来的会话**
- iCloud Documents 默认按需下载(§7.3)
- 点 Settings → iCloud 同步 → **"立即从 iCloud 拉取"** 按钮
- 或冷启动一次 app,会自动 trigger 一次延迟下载

### [共通] 另一端新增的 Chair / Summary / 新轮回答在本端看不到
- 见 §7.12 — 已修(scenePhase 监听)
- 历史数据丢失的会话:iCloud Drive 保留 30 天版本历史,可用 NSFileVersion API 救
- Mac 本机最后兜底:`~/.kown/logs/<会话标题>/` 里有每次 provider 调用的全文(只含本机调用)

### [共通] Firecrawl key 每次启动显示"未设置"
- 见 §7.13 — 已修(refreshHasWebSearchKey)
- 任何派生自 Keychain/Store 的缓存值都要在 syncedDataDir 切换时重算

### [iOS] 提交 TestFlight 每次问 encryption
- 见 §7.11,Info.plist 加 `ITSAppUsesNonExemptEncryption: false`

### [共通] Xcode Archive 每次问 Team
- 见 §7.10,project.yml 加 `DEVELOPMENT_TEAM`

### [共通] 切换 iCloud 开关时 app 卡死几秒~几十秒
- 已在 0.4.2 修(§7.4),如果还遇到说明你跑的是更老版本

### [共通] 公证密码 / 私钥访问每次都要确认
- 公证密码:跑过一次 `notarytool store-credentials kown-notarize`,后续 `--keychain-profile kown-notarize --keychain "$HOME/Library/Keychains/login.keychain-db"` 自动取
- codesign 私钥访问弹窗:点 **`Always Allow`**(不是 `Allow`),或 Keychain Access → 找到对应私钥 → Get Info → Access Control → 把 `codesign` 加进始终允许列表

### [macOS] 收件人开 .app 弹 `"X" is an app created by the app WeChat`
- 不是 bug,是 quarantine 二次确认对话框(§7.8)
- 治本:让对方 `xattr -dr com.apple.quarantine /Applications/<App>.app`
- 治本之上:.pkg 安装包或换 AirDrop 传

### [macOS] 收件人在 DMG 里直接点 .app → 行为异常 / 启动报错
- App Translocation(§7.9)
- 必须先把 .app 拖到 /Applications,再 eject DMG,再启动

### [共通] 多设备同一时间编辑导致冲突
- 系统默认 last-writer-wins;严重冲突会生成 `<name> 2.json` 副本
- 当前 UI 不显示冲突副本,后续可加 NSMetadataQuery 监听

---

## 10. 关键 Team ID 区分

用户 Apple ID 同时属于两个 Team(同 Apple ID 可加入多个 Team):

| Team ID | 来源 | 用途 |
|---|---|---|
| `QV55WUF9MA` | Personal Team(免费,Xcode 登录 Apple ID 自动赋予) | 仅 dev signing 装自己设备,**无 iCloud / Developer ID** |
| **`4257SFGRFK`** | **Apple Developer Program**(付费,¥688/年) | iCloud Container / App ID / Developer ID 都在这里 |

证书 CN 字段会显示 `(QV55WUF9MA)` 是历史标记,**实际 Team ID 看 OU 字段 = `4257SFGRFK`**。所有 iCloud 配置走 `4257SFGRFK`。

---

## 11. 主要决策与缘由

- **iCloud Drive Documents Container** vs CloudKit:前者改动 < 80 行,文件级冲突由系统处理;CloudKit 需重写存储层 5-10x 工作量。
- **API Key 跟随同步** vs 不同步:用户选了简化(每台手填太麻烦)。容器对 Files app 隐藏作为缓解。
- **不用 SwiftData / Core Data + NSPersistentCloudKitContainer**:现有存储是 JSON 文件,迁移到 ORM 是大工程,且 SwiftData 对多端冲突反而更黑盒。
- **NSUbiquitousContainerIsDocumentScopePublic=false**:容器内文件不暴露到用户的 iCloud Drive 列表,API Key 不会被用户误删 / 误传 / 看到明文。
