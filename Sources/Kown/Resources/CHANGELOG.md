# 更新日志

## 0.6.21 — 2026-05-29
### 维护
- **加单元测试 + CI** — 覆盖踩过坑的点:SSE `\r\n` 事件边界、会话按 id 去重、Workspace `kown:write` 解析与路径安全(拒 `../` 越界 / 非文本后缀);push / PR 到 main 自动在 macOS 跑 `swift test`。无功能改动

## 0.6.20 — 2026-05-29
### 修复
- **设置导航点击范围修复** — 左侧导航整行都可点击切换,不再只有图标或文字响应
- **设置页品牌图标统一** — 左上角图标改为与应用 App Icon 保持一致

## 0.6.19 — 2026-05-29
### 改进
- **全应用 UI 统一升级** — 主工作区、空状态、输入栏、模式切换、Provider 状态栏、对话/回答卡片、侧边栏、设置子页统一为新版 material + gradient + badge 视觉语言
- **对话阅读体验优化** — Direct / Compare / Council / Debate 的 turn 容器、角色标签、实时回答、工具事件和错误/等待状态层级更清楚
- **设置子页整体抛光** — Web Search、iCloud、备份、用量、性能、软件更新页增加 hero/summary 区块和统一状态卡片

## 0.6.18 — 2026-05-29
### 改进
- **更新日志页面重做** — 从原来的 GitHub Markdown 直出改成卡片式时间线,最新版本突出展示,历史版本分组更清晰
- **更新类型视觉化** — 修复 / 改进 / 改回 使用不同图标和颜色,设置页内嵌时自动隐藏重复标题和按钮

## 0.6.17 — 2026-05-29
### 改进
- **macOS 设置页重做** — 从顶部胶囊 tab 改成固定侧边栏 + 顶部上下文标题,Provider 页增加启用数量、Chair、Summary、CLI 摘要卡片,整体层级更清楚
- **设置窗口固定尺寸** — macOS 设置 sheet 固定为 `960 × 660`,切换 tab 时不再因为内容宽高不同一跳一跳

## 0.6.16 — 2026-05-29
### 修复
- **「安装并重启」按钮无效、要手动退出才更新** — 进程级抓包确认:点按钮后 Sparkle 的安装器(`Autoupdate` / `Updater.app`)起来了,但 Kown 进程没退出,安装器就一直死等。根因:Sparkle 因后台更新检查未声明 gentle reminders,把 Kown 当 background app,不替它终止进程。修复:UpdaterService 实现 `SPUStandardUserDriverDelegate`(声明支持 gentle reminders,让 Sparkle 走前台「终止并重启」流程)+ `SPUUpdaterDelegate.updaterWillRelaunchApplication` 兜底强制 `terminate`。注:本修复在新版本生效——升到 0.6.16 之后,之后的更新点按钮即可自动重启

## 0.6.15 — 2026-05-29
### 改进
- **每次打开 App 都做一次后台静默更新检查** — 之前只靠 Sparkle 的每日定时器(`SUScheduledCheckInterval=86400`),距上次检查不满 24h 就不查,所以新版发出来后不会马上发现。现在启动时额外强制一次 `checkForUpdatesInBackground`(尊重"自动检查"开关):开了自动下载就静默装、下次启动生效,否则弹更新窗

## 0.6.14 — 2026-05-29
### 修复(严重)
- **iCloud 迁移卡死 + 冲突副本根治** — `copyTree` 之前用裸 `FileManager.copyItem` 直接读写 iCloud 容器:读云端 placeholder 会同步阻塞等 materialize(FileProvider 忙时整迁移卡死在某个文件上 100% 不动),未协调的写入又让 iCloud 把同名文件 fork 成 `.kown 2/3/4...`(那上千个冲突文件的来源)。现在每个文件走 `NSFileCoordinator` 协调读写 —— 读端先把云文件拉下来再交付,写端拿独占 slot 再落盘,既不会无限卡,也不再生成冲突副本。migrate / mirror / reconcile 三条路径都受益

## 0.6.13 — 2026-05-29
### 修复(严重)
- **自动更新无限循环 /「安装并重启」不生效** — 之前每个发布的包 `CFBundleVersion` 都被硬编码成 `1`,而 appcast 的 `sparkle:version` 用 git 提交数(单调递增)。装好新版后 app 仍报 build 1,Sparkle 一比 `8 > 1` 又弹更新,点安装重启后还是 build 1 → 死循环。现在 `CFBundleVersion` 走 `$(CURRENT_PROJECT_VERSION)`,由 CI 注入 git 提交数,和 appcast 对齐,Sparkle 正确识别"已是最新"
### 修复
- **侧边栏会话列表大片空白 / 重复** — iCloud 冲突会生成「`<id> 2.json`」副本,`loadAll` 把同一个 id 读成多份,SwiftUI `ForEach` 拿到重复 Identifiable id 导致布局错乱。现在按 id 去重,保留 `updatedAt` 最新的一份
### 改进
- **设置顶部 tab 放不下文字时自动只显示图标**(`ViewThatFits`)— 标签宽度不够不再挤成两行,退化成纯图标 + tooltip
- **更新弹窗不再嵌入 GitHub 网页**(`SUShowReleaseNotes=NO`)— 只保留版本说明文字与按钮(0.6.13 起生效)

## 0.6.11 — 2026-05-28
### 改回
- **Gemini 改回 SSE 流式**(`streamGenerateContent?alt=sse`)— 字一段段实时显,体验更好。0.6.10 的 `generateContent` 一次返回的方式回退。CRLF 解析早已修好(0.6.6),thoughtSignature 也带了(0.6.7),SSE 路径稳定

## 0.6.10 — 2026-05-28
### 改进
- **Gemini 请求换 `generateContent`**(非流式)— 之前用 `streamGenerateContent?alt=sse` 经过 SSE 解析器,踩过 CRLF 边界 bug;改成单次 JSON 响应更稳。文字一次性到位由 ResponseState 节流到 ~20Hz 渲染,UI 体验差异肉眼无感

## 0.6.9 — 2026-05-28
### 改进
- **测试连接成功时也提供复制按钮** — 0.6.8 只对失败给了复制,现在成功也一样的卡片样式 + 复制按钮。成功消息里 sample 不再截到 24 字符,完整粘出来

## 0.6.8 — 2026-05-28
### 改进
- **测试连接的错误信息可复制 + 全文展示** — 之前 Label 会截断长错误,选中复制也不全。现在错误框里可选 + 一键复制按钮,Google / Anthropic 返回的完整 JSON 详情(`reason`、`retryDelay`、`quotaMetric` 等)都能直接拷给我看。错误体内部截断从 1500 放宽到 4000 字符

## 0.6.7 — 2026-05-28
### 修复
- **Gemini 工具调用 400** — Gemini 2.5+ 思考模型在 functionCall part 上挂 `thoughtSignature`,下一轮 echo 必须原样回传,否则报 `Function call is missing a thought_signature in functionCall parts`。现在 RoundResult 跟踪每个 functionCall 对应的 signature(以及纯 thinking part 的 signature),echo 时附在对应 part 上。网络搜索等工具调用正常工作

## 0.6.6 — 2026-05-28
### 修复(严重)
- **Gemini 响应全空** — `SSELineStream` 判事件分隔时用的是 `line.isEmpty`,但 Gemini SSE 用 `\r\n\r\n` 分隔事件,行末多个 `\r` 让 `"\r" != ""` 永远进不了事件边界分支。所有 `data:` 行累到流末尾合成 1 个事件,`JSONSerialization` 解多个 JSON 拼成的字符串失败 → 空响应。改成先 trim `\r` 再判空。Anthropic / OpenAI 之前没踩中是因为他们用纯 `\n\n`

## 0.6.5 — 2026-05-27
### 修复(严重)
- **彻底防止 iCloud `.kown N` 冲突再生**:加 `readyForCloudWrite` 闸门 — 启动后**等本地 `.kown` 真正出现**(iCloud 把 placeholder 同步下来)或 10s timeout 才允许写 iCloud。之前 store 们的 `createDirectory(intermediates:true)` 会在 iCloud 还没同步好时凭空建一个空 `.kown`,跟云上有数据的 `.kown` 撞车,macOS 把云上的重命名成 `.kown 2/3/4...`,用户视角就是"会话突然没了"
- 闸门关着期间所有写入落本地 `~/.kown`,等闸门一开自动 refresh 把数据从 iCloud 拉回来,不会丢
- AppViewModel 启动 refresh 现在等闸门开了再跑,而不是固定 2s

## 0.6.4 — 2026-05-27
### 修复
- **iCloud 状态"已登出或暂时不可达"误报** — `containerDocumentsURL` 被推迟到 reconcile 跑完才赋值(reconcile 可能要几分钟,逐个 download iCloud 占位文件),期间 UI 一直显灰、清理 card 也出不来。改成先 set URL 让 UI 立刻拿到正确状态,reconcile 后台跑
- **减少冲突触发概率** — `activeDataDirectory` 不再 eager `createDirectory(.kown)`,只在真正写入时由具体 store 建。iCloud 还没拉下来 `.kown` 时不再先抢着造一个空的撞车

## 0.6.3 — 2026-05-27
### 性能
- **会话存盘节流** — Council 一轮多家 provider 完成各触发一次 save,长会话 80K+ JSON 反复写盘很费;同一会话 300ms 内多次 save 合并为 1 次。app 失焦 / 进入后台时强制 flush 防丢
- **日志自动轮转** — 启动时清掉 `~/.kown/logs/` 里 14 天前的旧 `.md` 日志,防止只增不减堆爆
### 新增
- **iCloud 冲突备份清理** — Settings → iCloud 同步 里,若历史上有 `.kown N` 冲突备份目录(0.6.2 自愈过的),会显示文件计数 + 一键删除按钮释放 iCloud 配额

## 0.6.2 — 2026-05-27
### 修复(严重)
- **iCloud 冲突自愈** — 历史上若发生过 `.kown` → `.kown 2` 这种 iCloud 重命名冲突(常见于多设备首次同步竞争),启动时会自动把 `.kown N` 兄弟目录里的内容 merge 回 `.kown`,skip 已存在的,不覆盖。**没有数据会真的丢**,只是之前在另一个文件夹里看不到
- 备份目录 `.kown N` 不删,留作人工核对

## 0.6.1 — 2026-05-27
### 新增
- **流式刷新间隔可配** — Settings → 性能 tab,可选 30 / 50 / 100 / 200 / 500ms。默认 50ms ≈ 20Hz 适合大多数机器;低性能 / 老 Intel Mac 可拉到 100~500ms 进一步降 CPU

## 0.6.0 — 2026-05-27
### 性能
- **流式响应 CPU 占用大幅下降** — 之前流式期间每个 chunk(一秒几十个)都触发 SwiftUI 整树 layout 重算,响应越长 CPU 越炸(单核 100%)。改成 50ms 合批 flush + 流式期间关掉 textSelection,Council 多列并发 CPU 通常 < 30%
- 实测:8K token 长回答,从 layout pass 占用 ~83% CPU → ~10%

## 0.5.9 — 2026-05-27
### 新增
- **用量按设备查看** — Settings → 用量 顶部新增「全部设备 / 仅本机」切换,可单独看当前这台设备产生的 token 消耗

## 0.5.8 — 2026-05-27
### 新增
- **拖到 Applications 安装** — DMG 双击挂载后窗口里直接显示 `Kown.app` 和 `Applications` 文件夹,左拖右即装
### 修复
- **多设备用量累加** — 启动时 iCloud 拉下其他设备的 `usage-*.json` 后,UsageStore 现在会自动 reload,不用切 iCloud 开关才能看到累计

## 0.5.7 — 2026-05-27
### 修复
- **修复其它机器首次打开闪退** — SPM 生成的 `Bundle.module` 静态初始化在新版 macOS 上偶发 fatalError,导致 app 启动崩。改成直接走 `Bundle.main` 读 CHANGELOG.md,绝不再让"资源找不到"把 app 干掉

## 0.5.6 — 2026-05-27
### 维护
- 重新打包,无功能改动

## 0.5.5 — 2026-05-27
### 修复 / 改进
- **Token 用量改 per-device 文件 + iCloud 累加**:每台设备写自己的 `usage-<deviceID>.json`,读时合并所有设备的数据。多端用量真正累加,不会被某一台覆盖
- UI 显示"X 台设备"标识,提示当前是多设备汇总
- 旧 `usage.json`(本地单文件)自动迁移成新格式
- iCloud 同步刷新时自动 reload 用量(其他设备的最新数据立刻可见)

## 0.5.4 — 2026-05-27
### 新增
- **Token 用量统计** — Settings → "Token 用量" tab,按天 + 按 (provider, model) 分组,显示 input / output / 总 tokens + 调用次数
- 三家 client(OpenAI 兼容 / Anthropic / Gemini)都接入了 usage 上报
- 数据本地化(`~/.kown/usage.json`),不参与 iCloud 同步 — 每台机器自己的统计
- 一键清空全部历史

## 0.5.3 — 2026-05-27
### 新增
- **更新日志** 功能上线 — 每次更新后自动弹出"What's New",随时可在 设置 → 更新日志 翻历史
- CHANGELOG.md 嵌入 app bundle,跟代码一起版本化

## 0.5.2 — 2026-05-27
### 修复 / 改进
- **Workspace 写入解析更鲁棒** — 支持大小写不敏感、`kown-write` / `kown_write` 变种、路径后允许加语言名、闭围栏可带尾随空白
- Model 输出非 `kown:write` 格式的代码块时,UI 主动提示"用错格式了"
- system prompt 加了 ✅ / ❌ 正反例,引导 model 准确使用 `kown:write` 块

## 0.5.1 — 2026-05-27
### 修复
- **启动卡死修复** — `scenePhase` 首次 `.active` 不触发 refresh,文件下载枚举派到后台 thread
### 新增
- **新会话默认开启网络搜索** 偏好(设置 → Web Search)— 启用后启动 / 切换会话自动点亮 🌐
- macOS 启动闪屏 — 与 iOS 视觉一致
- iOS / macOS 图标统一
### 改进
- 输入栏精简,移除附件 / 日志按钮

## 0.5.0 — 2026-05-27
### 新增
- **Working Folder(工作目录)** 功能上线!macOS 选一个文件夹作为会话上下文:
  - Model 看到目录树 + 所有文本文件内容
  - Model 输出 ```kown:write <相对路径>\` 块自动写盘
  - 严格路径校验(`..` 越界、绝对路径拒绝)
  - 文件后缀白名单(.md / .swift / .py / .ts / .json / .yaml / 等)
  - 单文件 1MB / 总上下文 80KB 上限

## 0.4.9 — 2026-05-26
### 新增
- 会话顶端显示 Workspace 完整路径,可点击在 Finder 中打开 / 一键解除

## 0.4.8 — 2026-05-26
### 新增
- Working Folder 雏形

## 0.4.7 — 2026-05-26
### 修复
- **切换会话不再打断后台请求** — 跑的 task 继续在原会话上,切换会话只影响 UI 显示
- 发送按钮根据当前是否查看正在跑的会话,智能切换"发送 / 停止"

## 0.4.6 — 2026-05-26
### 改进
- **模型回答跨段拖选** — 用 `Text(AttributedString(markdown:))` 渲染,SwiftUI 选择可跨段
- 代码块 / 表格仍走 MarkdownUI 保留视觉

## 0.4.5 — 2026-05-26
### 修复
- App 切到前台时**自动从 iCloud 拉取最新数据** — Chair / Summary 等输出在两端立即可见
- iOS 加密合规设置:`ITSAppUsesNonExemptEncryption: false`,免每次提交问加密
- Xcode `DEVELOPMENT_TEAM` 写死,Archive 不再问 Team

## 0.4.4 — 2026-05-26
### 修复
- Firecrawl key 启动时假"未设置" — iCloud 容器探测异步,在容器到位 / 同步切换时重算缓存

## 0.4.3 — 2026-05-26
### 修复
- **重大修复**:Developer ID + iCloud entitlements 必须嵌入 provisioning profile
- 不嵌入 → 别人 Mac 上启动报"应用程序无法打开" — release.sh 加了 embed 步骤
- 公证凭据存储 / 跨设备分发链路打通

## 0.4.2 — 2026-05-26
### 修复
- iCloud 切换开关时 UI 卡死 — 文件拷贝派到 detached task
- iPhone 端拉不到 macOS 会话 — iCloud Documents 默认按需下载,触发 `startDownloadingUbiquitousItem`
- Settings → iCloud 同步 加 **"立即从 iCloud 拉取"** 按钮

## 0.4.1 — 2026-05-25
### 新增
- **iCloud Drive 同步** 上线 — 会话 / Provider / Web Search / API Key 跨设备同步
- 容器对 Files app 隐藏,API Key 不会出现在 iCloud Drive 列表
- 配置导入 / 导出 — JSON 备份文件,覆盖 / 合并两种模式

## 0.4.0 — 2026-05-25
### 新增
- **Debate 模式深度优化**:
  - 轮数可配置(1~4 轮)
  - 反驳轮不喂自家立论,减少 self-consistency 锚定
  - Moderator 输出加 "立场变迁" 维度
  - 反驳轮支持图片 / Web Search
- **单家失败可重试** — Panel 卡片 + Moderator/Chair/Judge/Summary 失败时,卡片角落出现 ↻ 重试,只重跑这一家

---

## 之前版本

更早的功能(0.3.x 及之前)未在此追溯。从 0.4.0 起逐版本记录。
