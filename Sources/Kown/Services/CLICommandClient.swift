import Foundation

#if os(macOS)
/// Runs a local CLI tool as a subprocess, streams its stdout line-by-line.
/// macOS 限定 — iOS 沙箱不能起子进程。
///
/// Args template supports a `{prompt}` placeholder that is substituted with the
/// user's prompt as a single argument. If the template has no `{prompt}`, the
/// prompt is piped via stdin instead.
struct CLICommandClient: LLMClient {

    func stream(prompt: String,
                options: ChatOptions,
                config: ProviderConfig,
                apiKey: String) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // CLI 不参与工具调用 — 若上层带了 🌐,在这里给个友好提示。
                if options.toolContext != nil, !options.tools.isEmpty {
                    continuation.yield(.toolEvent("⚠ CLI 不支持工具调用,本次跳过"))
                }
                let promptToSend = flattenPromptForCLI(
                    prompt: prompt,
                    summary: options.contextSummary,
                    priorTurns: options.priorTurns,
                    includeCurrentTime: options.toolContext != nil
                )
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                var outFileURL: URL? = nil

                do {
                    let cmd = (config.cliCommand ?? "").trimmingCharacters(in: .whitespaces)
                    guard !cmd.isEmpty else {
                        throw LLMError.badURL("未配置命令 (cliCommand)")
                    }
                    guard let executable = Self.resolveExecutable(cmd) else {
                        throw LLMError.badURL("找不到可执行文件: \(cmd)。可在配置里填绝对路径，例如 /opt/homebrew/bin/\(cmd)")
                    }

                    let template  = config.cliArgs ?? "-p {prompt}"
                    let usesStdin = !template.contains("{prompt}")
                    let usesFile  = template.contains("{outfile}")

                    if usesFile {
                        outFileURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent("kown-\(UUID().uuidString).txt")
                    }

                    let args = Self.buildArgs(
                        template: template, prompt: promptToSend, outFile: outFileURL?.path,
                        temperature: options.temperature
                    )

                    process.executableURL  = executable
                    process.arguments      = args
                    process.standardOutput = stdoutPipe
                    process.standardError  = stderrPipe

                    if usesStdin {
                        let stdinPipe = Pipe()
                        process.standardInput = stdinPipe
                        try stdinPipe.fileHandleForWriting.write(contentsOf: Data(promptToSend.utf8))
                        try stdinPipe.fileHandleForWriting.close()
                    } else {
                        // 避免子进程读不到 EOF 而卡住 / 打印"reading stdin..."
                        process.standardInput = FileHandle.nullDevice
                    }

                    // GUI 启动的进程 PATH 很小,补上常见路径
                    var env = ProcessInfo.processInfo.environment
                    let home = NSString(string: "~").expandingTildeInPath
                    let extras = [
                        "/opt/homebrew/bin", "/usr/local/bin",
                        "\(home)/.local/bin", "\(home)/bin",
                        "/usr/bin", "/bin",
                    ]
                    let current = env["PATH"] ?? ""
                    env["PATH"] = (extras + (current.isEmpty ? [] : [current])).joined(separator: ":")
                    process.environment = env

                    try process.run()

                    if usesFile {
                        // Batch 模式: 不流式输出,等进程结束后读文件
                        process.waitUntilExit()
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }
                        try Self.checkStatus(process: process, stderr: stderrPipe)
                        if let url = outFileURL,
                           let text = try? String(contentsOf: url, encoding: .utf8) {
                            continuation.yield(.text(text))
                            try? FileManager.default.removeItem(at: url)
                        }
                    } else {
                        // 流式: 逐行 yield stdout
                        for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                            if Task.isCancelled { break }
                            continuation.yield(.text(line + "\n"))
                        }
                        process.waitUntilExit()
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }
                        try Self.checkStatus(process: process, stderr: stderrPipe)
                    }

                    continuation.finish()
                } catch {
                    if process.isRunning { process.terminate() }
                    if let url = outFileURL { try? FileManager.default.removeItem(at: url) }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func checkStatus(process: Process, stderr: Pipe) throws {
        guard process.terminationStatus != 0 else { return }
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let errMsg  = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = errMsg.isEmpty
            ? "进程退出码 \(process.terminationStatus)"
            : errMsg
        throw LLMError.httpError(
            status: Int(process.terminationStatus),
            body: body
        )
    }

    // MARK: - Helpers

    /// Look up an executable by name in PATH + common locations.
    /// Absolute and ~-prefixed paths are returned as-is (after expansion).
    static func resolveExecutable(_ name: String) -> URL? {
        if name.hasPrefix("/") || name.hasPrefix("~") {
            let expanded = NSString(string: name).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        let home = NSString(string: "~").expandingTildeInPath
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var candidates: [String] =
            envPath.split(separator: ":").map(String.init)
            + [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "\(home)/.local/bin",
                "\(home)/bin",
                "/usr/bin",
                "/bin",
            ]
        // 探测最新的 nvm node 版本目录
        let nvmDir = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            for v in versions.sorted().reversed() {
                candidates.append("\(nvmDir)/\(v)/bin")
            }
        }
        for dir in candidates {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// Tokenize args template, substituting placeholders.
    /// `{prompt}`      → the prompt as a single arg
    /// `{outfile}`     → path to a temp file (caller passes via outFile param)
    /// `{temperature}` → 温度值(如 0.7);未配置温度时该 token 整个丢弃,
    ///                   不会以字面量 / 空串形式传给子进程。
    static func buildArgs(template: String, prompt: String, outFile: String?,
                          temperature: Double?) -> [String] {
        // nil 温度时用哨兵标记 {temperature},随后过滤掉
        let dropSentinel = "\u{0}__kown_drop__"
        return template
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .map {
                switch $0 {
                case "{prompt}":  return prompt
                case "{outfile}": return outFile ?? $0
                case "{temperature}":
                    guard let t = temperature else { return dropSentinel }
                    return String(format: "%g", t)
                default:          return $0
                }
            }
            .filter { $0 != dropSentinel }
    }
}

#endif
