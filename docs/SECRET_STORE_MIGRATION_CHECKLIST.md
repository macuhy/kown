# Secret Store 迁移手工验证 Checklist

适用场景:把 `KeychainStore` 的默认本机 JSON secret store 显式 opt-in 迁移到 Security/Keychain Services 后端前后,做 macOS / iOS smoke。当前设计仍是"每台设备独立密钥":Security 后端使用 `kSecAttrSynchronizable=false`,不把 API Key 通过 iCloud Keychain 同步。

> 约束:只有用户显式选择 Security Keychain 后端/迁移按钮/实验开关时才迁移。迁移失败或校验失败时,不得激活目标后端,也不得删除原 `apikeys.json`。

## 0. 环境记录

| 项 | macOS | iOS |
|---|---|---|
| App build / commit | [ ] | [ ] |
| 安装方式(Debug / TestFlight / Release) | [ ] | [ ] |
| iCloud Drive 状态 | [ ] 开 / [ ] 关 | [ ] 开 / [ ] 关 |
| Secret store 后端 | [ ] JSON / [ ] Security | [ ] JSON / [ ] Security |
| 测试设备 | [ ] | [ ] |

预置数据:
- [ ] 至少 1 个 OpenAI-compatible Provider,且已保存 API Key。
- [ ] Firecrawl 已配置 baseURL + API Key。
- [ ] GitHub Device Flow 已连接或准备好重新连接。
- [ ] TTS 至少验证 1 个需 key 的引擎:SiliconFlow 或 Xunfei。
- [ ] 准备一份不含 Key 的配置备份,以及一份显式"包含 API Key"的配置备份。

## 1. 迁移前 JSON 后端基线

### macOS

- [ ] 保存 Provider API Key 后,Provider 行显示已配置;发送 `ping` 或点击 Provider 测试能成功返回。
- [ ] 退出 App 并重新打开后,同一 Provider 仍能加载 Key 并完成一次最小请求。
- [ ] Web Search 设置里保存 Firecrawl Key;开启联网后发一个需要搜索的问题,确认工具调用成功。
- [ ] 退出/重启 App 后,Firecrawl 仍显示已配置,再次搜索成功。
- [ ] GitHub 连接后能列出仓库或写入一个测试文件;退出/重启后仍显示已连接。
- [ ] TTS 设置里保存 SiliconFlow Key 或 Xunfei APIKey/APISecret;播放一段短文本成功。
- [ ] 退出/重启 App 后,TTS 不需要重新填 Key,再次播放成功。
- [ ] `~/.kown/apikeys.json` 权限为 `0600`,且不在 iCloud 容器里。

### iOS

- [ ] 保存 Provider API Key 后,发送 `ping` 或最小 prompt 成功。
- [ ] 杀掉 App 进程并重新打开后,同一 Provider 仍能加载 Key 并完成请求。
- [ ] Firecrawl 保存、开启、搜索成功;杀进程重开后仍成功。
- [ ] GitHub 连接、仓库读取/测试写入成功;杀进程重开后仍显示已连接。
- [ ] TTS 需 key 引擎播放成功;杀进程重开后仍成功。
- [ ] 如需查看容器,通过 Xcode Devices 下载 App container;确认敏感 key 不在 iCloud Documents 容器。

## 2. Keychain 集成测试命令

在本仓库根目录运行:

```bash
KOWN_RUN_KEYCHAIN_INTEGRATION=1 swift test --filter SecurityKeychainIntegrationTests
```

补充跑迁移/备份相关单元测试:

```bash
swift test --filter KeychainStoreBackendTests
```

通过标准:
- [ ] 集成测试会真实写入系统 Keychain 的临时 service,并在测试结束清理。
- [ ] 未设置 `KOWN_RUN_KEYCHAIN_INTEGRATION=1` 时测试应 skip,避免 CI 或普通本地测试误碰真实 Keychain。
- [ ] 若 macOS 弹出 Keychain 访问确认,本轮记录弹窗内容;不要把测试 service 当成生产 service。
- [ ] 生产 service 期望为 `com.xiaobo.kown.apikey.v1`;抽查时只用 `security find-generic-password -s com.xiaobo.kown.apikey.v1 -a <provider-uuid>` 查看属性,不要加 `-g` 打印明文密码。

## 3. 显式 opt-in 迁移执行

迁移前:
- [ ] 导出一份"不包含 API Key"备份,确认文件可解析且无 `apiKeys` payload。
- [ ] 导出一份"包含 API Key"备份,确认仅保存在安全位置;当前手动导出会包含 Provider Key + Firecrawl Key。
- [ ] 记录 Provider UUID、Firecrawl 固定 UUID、GitHub token 状态、TTS 引擎与 Key 状态。
- [ ] 不手动删除 `~/.kown/apikeys.json` 或 iOS App container 内旧 JSON。

执行 opt-in:
- [ ] 触发 Security Keychain opt-in/迁移入口。
- [ ] UI 或日志显示 copied/verified key count;`activatedTarget=true` 只在目标 Keychain 读回完全一致后出现。
- [ ] 若迁移报错,确认 App 仍停留在 JSON 后端,Provider/Firecrawl/GitHub/TTS 仍可用。
- [ ] 若迁移成功,立刻退出并重开 App,确认后端仍为 Security,不是回落到 JSON。

迁移后不要立即清理:
- [ ] 至少完成本文件所有 smoke 后,再考虑清理旧 JSON。
- [ ] 清理前保留一份加密离线备份或可恢复的包含 Key 备份。

## 4. 迁移后 macOS smoke

Provider:
- [ ] 新增一个测试 Provider,保存 Key,立即测试成功。
- [ ] 编辑现有 Provider 的 Key,测试成功;删除 Key 后请求应明确提示未配置。
- [ ] 退出/重启 App 后,新增/编辑后的 Key 状态保持一致。

Firecrawl:
- [ ] Web Search Key 保存后,`🌐` 可启用。
- [ ] 普通联网搜索、Fact Check 或 Deep Research 任一链路成功。
- [ ] 清空 Firecrawl Key 后,`🌐` 不可启用或给出明确"需配置 Key"提示。
- [ ] 退出/重启后,清空/恢复状态保持一致。

GitHub:
- [ ] Device Flow 连接成功,App 显示已连接。
- [ ] 读取仓库列表或写入测试文件成功。
- [ ] 退出/重启后仍已连接;点击断开后 token 被清理。
- [ ] 断开后 GitHub 操作给出"未连接"提示,不会继续使用旧 token。

TTS:
- [ ] SiliconFlow Key 保存后短文本播放成功。
- [ ] Xunfei APPID + APIKey + APISecret 保存后短文本播放成功(如本轮覆盖 Xunfei)。
- [ ] 切到系统语音不依赖 Key;切回在线引擎后仍能读到迁移后的 Key。
- [ ] 退出/重启后在线引擎仍可播放。

备份:
- [ ] 手动导出且关闭"包含 API Key":备份不含 `apiKeys`;导入到干净环境后 Provider/Web Search 配置存在,但 Key 需要重新填。
- [ ] 手动导出且开启"包含 API Key":导入到干净环境后 Provider Key + Firecrawl Key 可用。
- [ ] 自动备份/立即自动备份路径不包含明文 Key。
- [ ] 当前代码的手动导出不主动包含 GitHub token / TTS Key;若产品决定扩展备份范围,需同步更新测试预期与 UI 警示。

iCloud 开关:
- [ ] iCloud 开启后,会话、Provider 非敏感配置、Web Search 非敏感配置同步;Key 不出现在另一台新设备上。
- [ ] iCloud 关闭后,云端非敏感配置镜像到本地;Security Keychain 中的 Key 不被删除。
- [ ] 开/关 iCloud 后立刻退出重开,Provider/Firecrawl/GitHub/TTS Key 状态不丢。
- [ ] iCloud 容器里没有新的 `apikeys.json`。

## 5. 迁移后 iOS smoke

Provider:
- [ ] 新增/编辑 Provider Key 后最小 prompt 成功。
- [ ] 杀进程重开后 Key 状态保持。
- [ ] 删除 Key 后请求失败信息明确,不会静默使用旧 Key。

Firecrawl:
- [ ] 保存 Firecrawl Key 后联网搜索成功。
- [ ] 杀进程重开后搜索仍成功。
- [ ] 清空 Key 后 `🌐` 不可用或提示需配置 Key。

GitHub:
- [ ] Device Flow 登录成功。
- [ ] 仓库读取/测试写入成功。
- [ ] 杀进程重开后仍已连接;断开后 token 清理。

TTS:
- [ ] SiliconFlow 或 Xunfei 播放短文本成功。
- [ ] 杀进程重开后仍成功。
- [ ] 切换系统语音和在线语音不会丢失在线引擎 Key。

备份:
- [ ] 不含 Key 导出导入后,配置存在但 Provider/Firecrawl Key 需重新填。
- [ ] 含 Key 导出导入后,Provider/Firecrawl Key 可用。
- [ ] 自动备份不含明文 Key。
- [ ] 若导入文件里手动包含 GitHub/TTS 固定 UUID,导入后应能补充到 secret store;默认导出不生成这些条目。

iCloud 开关:
- [ ] iCloud 开启/关闭不会改变 Keychain 后端里的 Key。
- [ ] 另一台设备同步到 Provider/Web Search 配置后,仍需要本机单独保存 Key 或导入含 Key 备份。
- [ ] 杀进程重开、设备锁屏再解锁后,Key 状态保持。

## 6. Keyboard / Watch 注意事项

Keyboard:
- [ ] 键盘扩展不能直接读取主 App 的本机 secret store,当前也未把 Keychain access group 当共享通道启用。
- [ ] 只有用户打开"共享模型配置给键盘"时,主 App 才把选中 Provider 的 baseURL/model/API Key 写入 App Group UserDefaults。
- [ ] 迁移后打开 AI 键盘开关,确认键盘可用;关闭开关后共享配置被清除。
- [ ] iOS 系统设置里需要添加 Kown 键盘并允许"完全访问";截图回复还需要完整照片权限。
- [ ] 删除 Provider Key 或切换 Provider 后,重新进入设置页应刷新键盘共享配置,不能继续使用旧 Key。

Watch:
- [ ] Apple Watch 不通过 App Group 或 iCloud 读取主 App Key;只接收 iPhone 经 `WCSession.updateApplicationContext` 推送的最新配置。
- [ ] 迁移后在 iPhone 触发"同步到 Apple Watch",Watch 端能收到 Provider baseURL/model/API Key。
- [ ] Firecrawl 已启用且有 Key 时,Watch payload 应同时带 Firecrawl baseURL/Key;未配置时不应带旧 Firecrawl Key。
- [ ] 删除 Provider Key 后再次同步,Watch 端应显示未配置或无法发送,不能继续使用旧 payload。
- [ ] Watch TTS/播放能力按 watchOS 音频限制验证;不要把 Watch 端问题误判为主 App Keychain 迁移失败。

## 7. 回滚与放行

回滚条件:
- [ ] 任一核心 secret 在迁移后无法读回,或 copied/verified count 不一致。
- [ ] iCloud 开关、退出重启或杀进程后 Key 状态丢失。
- [ ] Keyboard/Watch 仍能使用已删除的旧 Key。
- [ ] 备份不含 Key 时泄露了明文 secret,或自动备份包含明文 secret。

回滚步骤:
- [ ] 关闭 Security Keychain opt-in,恢复 JSON 后端。
- [ ] 如 JSON 仍存在,确认 Provider/Firecrawl/GitHub/TTS 全部恢复可用。
- [ ] 如 JSON 已被误删,用加密保存的含 Key 备份恢复 Provider/Firecrawl;GitHub/TTS 需按当前产品策略重新登录/重新填写或导入包含固定 UUID 的备份。
- [ ] 记录失败平台、后端 service、OSStatus/错误文案、是否发生在退出重启或 iCloud 切换后。

放行标准:
- [ ] macOS 与 iOS 迁移前后 smoke 全绿。
- [ ] `KOWN_RUN_KEYCHAIN_INTEGRATION=1 swift test --filter SecurityKeychainIntegrationTests` 通过或在不支持环境中明确 skip。
- [ ] `swift test --filter KeychainStoreBackendTests` 通过。
- [ ] 未发现 Key 被写入 iCloud 容器或自动备份。
- [ ] Keyboard/Watch 对"显式共享/推送"的用户提示与实际行为一致。
