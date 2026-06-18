# AI 转型先锋奖 · 申报材料

## 我如何通过独立开发一款 AI 原生应用完成个人转型

---

## 一、个人简介

我是一名软件工程师。在 AI 大模型浪潮来临之际，我没有选择观望，而是亲手从零开始构建了一款名为 **Kown**（谐音"Know" + "Own"）的全平台 AI 智能助手应用，覆盖 iOS 与 macOS 双端。这个项目既是我拥抱 AI 的实践，也是我完成从传统开发者向 **AI 原生产品创造者** 转型的完整历程。

---

## 二、转型背景：为什么要做 Kown

2024 年起，ChatGPT、Claude、Gemini、文心一言、讯飞星火等大模型百花齐放，但实际使用中我遇到了几个核心痛点：

1. **模型分散**：每个模型都有独立的入口，频繁切换效率极低。
2. **能力各有所长**：不同任务适合不同模型，没有一个模型能通吃所有场景。
3. **缺乏深度集成**：现有客户端大多是简单的聊天窗口，缺少知识管理、语音交互、工具调用等高级能力。
4. **隐私与控制**：作为专业用户，我希望自己掌控 API Key 和数据流向。

**我的判断是：AI 时代真正需要的不是又一个聊天界面，而是一个以 AI 为核心的智能工作中枢。**

于是我决定自己动手，把转型的"第一枪"打在产品实践上。

---

## 三、Kown 是什么

**Kown** 是一款 AI 原生的全平台智能助手，使用 Swift / SwiftUI 原生开发，支持 iOS 和 macOS。它不是对某个大模型的简单包装，而是一个 **多模型协同、多模态交互、深度工具集成** 的 AI 工作台。

### 核心定位

> **一个入口，连接所有 AI 能力；一个界面，完成所有思考与创作。**

---

## 四、核心能力与技术创新

### 4.1 多模型统一接入 —— "AI 路由器"架构

这是 Kown 最核心的设计。我构建了一套 **Provider（供应商）+ Model（模型）** 的统一抽象层，将市面上主流的 AI 服务全部接入到同一个界面中：

| 供应商 | 接入方式 | 典型模型 |
|--------|----------|----------|
| OpenAI | OpenAI API | GPT-4o, GPT-4.1, o1, o3, o4-mini |
| Anthropic | 原生 API 适配 | Claude 3.5 Sonnet, Claude 4 Opus/Sonnet |
| Google | Gemini API | Gemini 2.5 Pro/Flash |
| DeepSeek | OpenAI 兼容协议 | DeepSeek-V3, DeepSeek-R1 |
| 阿里云百炼 | OpenAI 兼容协议 | Qwen 系列 |
| 讯飞星火 | 自定义签名认证 | Spark 4.0 Ultra |
| 硅基流动 SiliconFlow | OpenAI 兼容协议 | 多种开源模型 |
| 自定义 | OpenAI 兼容协议 | 任意本地/私有部署模型 |

**技术实现要点：**

- **`ProviderRegistry`**（`Sources/Kown/Services/ProviderRegistry.swift`）：统一的供应商注册中心，管理所有 AI 服务的发现与路由。
- **`OpenAICompatibleClient`**（`Sources/Kown/Services/OpenAICompatibleClient.swift`）：实现 OpenAI 兼容协议的通用客户端，一套代码接入十余家供应商。
- **`AnthropicClient`**（`Sources/Kown/Services/AnthropicClient.swift`）：针对 Anthropic 独特的 Messages API 进行专门适配，支持 Extended Thinking（深度思考）流式输出。
- **`GeminiClient`**（`Sources/Kown/Services/GeminiClient.swift`）：适配 Google Gemini 原生协议。
- **`ProviderModelCatalog`**（`Sources/Kown/Models/ProviderModelCatalog.swift`）：内置 200+ 模型的完整目录，用户开箱即选。
- **`SSELineStream`**（`Sources/Kown/Services/SSELineStream.swift`）：自研 Server-Sent Events 流式解析器，保障实时打字机效果。

> **这意味着用户只需在一个应用内，就能随时在世界顶级的 AI 模型之间无缝切换。**

### 4.2 三种独创的 AI 对话模式

不同于传统聊天工具的单一对话，Kown 设计了三种开创性的对话模式：

#### 🎯 直接模式（Direct Mode）
最经典的一问一答。支持 Markdown 渲染、代码高亮、图片生成等全部能力。

#### ⚔️ 辩论模式（Debate Mode）
选择两个不同的 AI 模型，针对同一问题展开辩论。两个模型轮流发言，观点碰撞，帮助用户从多个角度理解问题。这是我在调研中发现的核心创新——**用 AI 的分歧来启发人类的思考**。

#### 🏛️ 委员会模式（Council Mode）
同时召集多个 AI 模型作为"委员"，并行回答同一问题，最后由一个"主席模型"汇总各方观点，形成综合结论并进行投票表决。这是对 **"AI 集体智慧"** 的工程化实现。

**技术实现要点：**

- **`AppViewModel+Send`**（`Sources/Kown/ViewModels/AppViewModel+Send.swift`，65.4KB）：这是整个应用最核心的文件，统一调度三种模式下的多模型并发请求、流式响应合并、错误处理与重试逻辑。
- **`CouncilTurnsView`** / **`DebateTurnsView`** / **`DirectTurnsView`**：三种模式各自有精心设计的专属 UI。
- **`Conversation`** 模型（21.4KB）：复杂的对话数据结构，支持多轮、多模型、多模式的完整状态管理与持久化。

### 4.3 深度思考（Reasoning）可视化

Kown 完整支持具有"思维链"能力的模型（如 Claude Extended Thinking、DeepSeek-R1、OpenAI o 系列），并创新地将 AI 的 **推理过程** 以可折叠的专属区域展示给用户（`ReasoningDisclosure.swift`），让用户不仅看到答案，更能看到 AI 是怎么想的。

### 4.4 联网搜索与信息增强

集成 **Firecrawl** 搜索引擎（`FirecrawlClient.swift`），让 AI 能够实时获取互联网最新信息。搜索结果以来源卡片形式展示（`SourcesStrip.swift`），支持标注引用序号，实现 **可溯源的 AI 回答**。

同时，内置 **`QuestionRouter`**（`Sources/Kown/Services/QuestionRouter.swift`）智能路由器，自动判断用户问题是否需要联网搜索，无需手动切换。

### 4.5 知识库与本地 RAG

- **`KnowledgeFolder`** + **`LocalRAG`**（`Sources/Kown/Services/LocalRAG.swift`）：用户可以导入自己的文档建立个人知识库，Kown 会基于本地向量检索（RAG）自动在对话中注入相关上下文，让 AI 的回答更贴合个人需求。
- **`AppViewModel+Knowledge`**：知识库与对话的深度联动逻辑。

### 4.6 语音交互全链路

- **`SpeechRecognizer`**（语音识别）：支持实时语音转文字输入。
- **`SpeechService`** + **`NeuralTTS`** + **`XunfeiTTSEngine`**（`Sources/Kown/Services/TTS/`）：多引擎 TTS 语音合成，支持系统语音和讯飞在线语音，可自定义语速、音色。
- **`VoiceConversationView`**（17.5KB）：完整的语音对话界面，支持连续对话模式。

### 4.7 丰富的效率工具

| 功能 | 实现文件 | 说明 |
|------|----------|------|
| 提示词库 | `PromptLibraryStore.swift` / `PromptLibraryView.swift` | 内置精选提示词 + 自定义管理 |
| 提示词历史 | `PromptHistoryStore.swift` | 自动记录，一键复用 |
| 对话导出 | `ConversationExporter.swift` | 支持 Markdown / PDF / 图片等多格式 |
| 对话搜索 | `ConversationSearchIndex.swift` | 全文检索所有历史对话 |
| iCloud 同步 | `ICloudSync.swift`（17.9KB） | 跨设备无缝同步对话与设置 |
| 备份恢复 | `BackupStore.swift`（12.5KB） | 完整的本地备份与恢复方案 |
| 快捷指令 | `AskKownIntent.swift` | 支持 iOS/macOS Shortcuts 集成 |
| 命令面板 | `CommandPaletteView.swift` | macOS 端 ⌘K 快速操作面板 |
| 全局快捷窗口 | `MacQuickAsk.swift` | macOS 全局快捷键随时唤起 AI |
| 分享扩展 | `ShareViewController.swift` | 从任意 App 直接分享内容到 Kown |
| 用量统计 | `UsageStore.swift` | Token 用量与费用追踪 |
| 自动更新 | `UpdaterService.swift` + Sparkle | macOS 端 OTA 自动更新 |

### 4.8 工程品质

- **完善的测试套件**：包含 `SSEParsingTests`、`ConversationCodableTests`、`TextDiffTests`、`LocalRAGTests`、`PromptBuildersTests` 等十余个测试文件，覆盖核心逻辑。
- **崩溃日志**：`CrashLogger.swift` 自建轻量级崩溃收集。
- **跨平台架构**：`Platform.swift` 统一平台差异，一套代码同时生成 iOS 和 macOS 应用。
- **XcodeGen 工程管理**：`mac/project.yml` + `ios/project.yml`，工程配置代码化。

---

## 五、转型成果

### 5.1 技术能力的全面跃迁

| 转型前 | 转型后 |
|--------|--------|
| 传统客户端开发 | AI 原生应用架构设计 |
| 单一 API 调用 | 多模型统一抽象 + 流式协议适配 |
| 基础 UI 开发 | 复杂多模态交互界面 |
| 本地数据存储 | RAG 向量检索 + iCloud 云同步 |
| 单平台开发 | iOS + macOS 全平台 |

### 5.2 产品思维的根本转变

这个项目让我从一个"写代码的工程师"转变为一个"用 AI 思考的产品创造者"：

- **我不是在用 AI 写代码，我是在为 AI 设计舞台。** Kown 的每一个功能都在思考：AI 能力应该如何被最优地呈现和组合？
- **辩论模式和委员会模式** 的设计，体现了我对"AI 不应只是工具，而应成为思维伙伴"这一理念的工程化实践。
- **深度思考可视化** 体现了我对 AI 透明性和可解释性的追求。

### 5.3 项目规模

通过代码库统计，Kown 项目核心代码（不含第三方依赖）的关键数据：

- **核心 Swift 源文件**：80+ 个
- **核心代码量**：约 900KB+（纯业务逻辑）
- **单最大文件**：`AppViewModel+Send.swift` 达 65.4KB，体现了多模型调度的复杂度
- **CHANGELOG 记录**：37.2KB 的持续迭代记录，体现了从 0 到 1 的完整演进
- **完整的版本发布体系**：`scripts/release.sh`（14.4KB）自动化发布脚本

---

## 六、转型方法论总结

回顾整个转型历程，我提炼出三个关键方法论：

### 1. 「边做边学」而非「学完再做」

我没有花几个月先去系统学习 AI 理论，而是直接从第一个 API 调用开始，在构建产品的过程中理解 Prompt Engineering、Streaming Protocol、Token 经济学、RAG 架构等核心概念。**实践是最好的老师。**

### 2. 「抽象统一」而非「逐个适配」

面对十余家 AI 供应商各自不同的协议，我没有为每一家写独立的客户端，而是设计了 `OpenAICompatibleClient` 这样的统一抽象层。**好的架构设计本身就是一种 AI 时代的核心竞争力。**

### 3. 「用 AI 增强 AI」的闭环

我在开发 Kown 的过程中，也大量使用 AI 来辅助编码和设计（项目中的 `CLAUDE.md` 就是为 AI 编程助手准备的项目上下文文件）。**用 AI 构建 AI 产品，本身就是最深度的 AI 转型实践。**

---

## 七、未来展望

Kown 仍在持续迭代中。未来计划包括：

- 更深度的 Agent 工作流（基于已有的 `ToolRouter` + `ToolDefinition` 工具调用框架）
- 多模态输入增强（图片理解已支持，视频/文件理解持续拓展）
- 本地模型集成（利用 Apple Silicon 的 MLX/CoreML 能力）
- 团队协作场景探索

---

## 八、结语

> **AI 转型不是一句口号，而是一行行代码、一个个功能、一次次迭代的累积。**

Kown 这个项目，是我用超过 80 个源文件、近千 KB 的代码、覆盖 iOS 和 macOS 双平台的工程实践，交出的一份 AI 转型答卷。

它证明了一件事：**一个传统开发者，通过深度理解 AI 能力、亲手构建 AI 原生产品，完全可以在这波浪潮中完成自我革新，从 AI 的旁观者变为 AI 的创造者。**

---

*文档生成时间：2026 年 6 月 4 日*
*项目地址：Kown Workspace*