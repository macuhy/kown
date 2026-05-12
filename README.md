# Kown — macOS LLM Council

并发请求多家大模型厂商,流式并排展示回答。Swift 6 + SwiftUI 原生 macOS 应用。

## 运行

```bash
swift run Kown
```

或在 Xcode 16 中打开 `Package.swift` 直接 ⌘R。

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

- API Key 存 macOS Keychain(service: `app.kown.apikey`,account: 厂商 UUID)
- 非密钥配置存 UserDefaults(key: `kown.providers.v1`)
