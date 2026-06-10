import Foundation
#if os(iOS)
import JavaScriptCore
#endif

/// 「代码执行」设备工具的全局开关(设置 ▸ 设备工具 ▸ 代码执行)。
/// 默认**关闭**;只有用户显式开启后,`run_code` 工具才会暴露给模型。
/// ⚠ 这不是真正的隔离沙盒:代码以用户权限在本机运行,设置页有醒目警示。
@MainActor
@Observable
final class CodeExecToolState {
    static let shared = CodeExecToolState()

    private static let enabledKey = "kown.codeExecTool.enabled.v1"

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    private init() {
        // 默认 false(key 不存在时 bool(forKey:) 返回 false)。
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }
}

/// 一次代码执行的结果(回灌给模型 + 步骤树摘要的数据源)。
struct CodeRunResult: Sendable {
    /// 进程退出码;iOS JavaScriptCore 路径用 0 / 1(有异常)模拟。
    var exitCode: Int32
    var stdout: String
    var stderr: String
    /// 实际耗时(毫秒)。
    var durationMS: Int
    /// 是否因 30s 超时被强杀。
    var timedOut: Bool
    /// 没跑起来的原因(如解释器未安装 / 平台不支持);nil 表示正常启动过。
    var failureReason: String?
}

/// 代码执行服务:macOS 用子进程跑 python3 / node,iOS 用 JavaScriptCore 跑 JS。
/// ⚠ 非隔离沙盒 —— 代码以当前用户权限在本机运行。约束:
/// - 工作目录 = 每次新建的临时目录,跑完即删(macOS)。
/// - 30 秒超时强杀(macOS SIGKILL / iOS JSC 执行时限)。
/// - stdout / stderr 各截断 20KB。
/// - 传最小环境变量,不读 stdin。
/// - 全程在后台线程执行,不阻塞主线程。
enum CodeSandboxService {
    static let timeoutSeconds: Double = 30
    static let maxCaptureBytes = 20 * 1024

    /// 支持的语言(按平台)。
    static var supportedLanguages: [String] {
        #if os(macOS)
        return ["python", "javascript"]
        #else
        return ["javascript"]
        #endif
    }

    /// 执行一段代码。永不抛错 —— 所有失败都折叠进 `CodeRunResult`。
    static func run(language: String, code: String) async -> CodeRunResult {
        let lang = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard supportedLanguages.contains(lang) else {
            return CodeRunResult(exitCode: -1, stdout: "", stderr: "", durationMS: 0, timedOut: false,
                                 failureReason: "不支持的语言「\(language)」,当前平台支持:\(supportedLanguages.joined(separator: " / "))")
        }
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CodeRunResult(exitCode: -1, stdout: "", stderr: "", durationMS: 0, timedOut: false,
                                 failureReason: "代码为空")
        }
        #if os(macOS)
        return await runProcess(language: lang, code: code)
        #elseif os(iOS)
        return await runJavaScriptCore(code: code)
        #else
        return CodeRunResult(exitCode: -1, stdout: "", stderr: "", durationMS: 0, timedOut: false,
                             failureReason: "当前平台不支持代码执行")
        #endif
    }

    /// 截断到 20KB(按 UTF-8 字节),被截断时追加说明。
    static func truncate(_ s: String) -> String {
        let data = Data(s.utf8)
        guard data.count > maxCaptureBytes else { return s }
        let head = data.prefix(maxCaptureBytes)
        let text = String(decoding: head, as: UTF8.self)
        return text + "\n…(输出超过 20KB,已截断)"
    }

    #if os(macOS)

    // MARK: - macOS:Process 子进程

    /// 最小环境变量。HOME 指到临时工作目录,避免解释器顺手读用户目录配置。
    private static let minimalPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    /// 在 PATH 候选目录里找解释器,找不到返回 nil(= 没装)。
    private static func findInterpreter(_ name: String) -> String? {
        for dir in minimalPATH.split(separator: ":") {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static func runProcess(language: String, code: String) async -> CodeRunResult {
        let (interpreter, ext, installHint): (String, String, String) = language == "python"
            ? ("python3", "py", "本机未检测到 python3,请先安装 Python(如 `brew install python` 或 Xcode 命令行工具)后重试。")
            : ("node", "js", "本机未检测到 node,请先安装 Node.js(如 `brew install node`)后重试。")
        // 启动前检测解释器可用性,没装就直接在结果里说明。
        guard findInterpreter(interpreter) != nil else {
            return CodeRunResult(exitCode: -1, stdout: "", stderr: "", durationMS: 0, timedOut: false,
                                 failureReason: installHint)
        }
        // 在专用 GCD 线程上同步跑(阻塞等待子进程),不占用 Swift 并发协作线程池。
        return await withCheckedContinuation { (cont: CheckedContinuation<CodeRunResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runProcessSync(interpreter: interpreter, ext: ext, code: code))
            }
        }
    }

    /// 同步执行子进程(在后台 GCD 线程调用)。
    /// stdout / stderr 重定向到临时文件 —— 避免 Pipe 缓冲区写满导致的子进程死锁。
    private static func runProcessSync(interpreter: String, ext: String, code: String) -> CodeRunResult {
        let fm = FileManager.default
        // 每次新建独立临时工作目录,跑完整体删除。
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("kown-run-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: workDir) }
        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        } catch {
            return CodeRunResult(exitCode: -1, stdout: "", stderr: "", durationMS: 0, timedOut: false,
                                 failureReason: "创建临时工作目录失败:\(error.localizedDescription)")
        }
        let scriptURL = workDir.appendingPathComponent("main.\(ext)")
        let stdoutURL = workDir.appendingPathComponent(".kown-stdout.log")
        let stderrURL = workDir.appendingPathComponent(".kown-stderr.log")
        do {
            try code.data(using: .utf8)?.write(to: scriptURL)
            fm.createFile(atPath: stdoutURL.path, contents: nil)
            fm.createFile(atPath: stderrURL.path, contents: nil)
        } catch {
            return CodeRunResult(exitCode: -1, stdout: "", stderr: "", durationMS: 0, timedOut: false,
                                 failureReason: "写入临时脚本失败:\(error.localizedDescription)")
        }
        guard let outFH = try? FileHandle(forWritingTo: stdoutURL),
              let errFH = try? FileHandle(forWritingTo: stderrURL) else {
            return CodeRunResult(exitCode: -1, stdout: "", stderr: "", durationMS: 0, timedOut: false,
                                 failureReason: "打开输出文件失败")
        }
        defer { try? outFH.close(); try? errFH.close() }

        let process = Process()
        // 用 /usr/bin/env 解析解释器(吃我们给的最小 PATH,覆盖 homebrew / 系统位置)。
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [interpreter, scriptURL.path]
        process.currentDirectoryURL = workDir
        // 最小环境变量:不继承用户 shell 环境;HOME/TMPDIR 指到临时目录。
        process.environment = [
            "PATH": minimalPATH,
            "HOME": workDir.path,
            "TMPDIR": workDir.path,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "PYTHONUNBUFFERED": "1",
            "NO_COLOR": "1"
        ]
        process.standardInput = FileHandle.nullDevice   // 不读 stdin
        process.standardOutput = outFH
        process.standardError = errFH

        let exitSem = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSem.signal() }

        let start = DispatchTime.now()
        do {
            try process.run()
        } catch {
            return CodeRunResult(exitCode: -1, stdout: "", stderr: "", durationMS: 0, timedOut: false,
                                 failureReason: "启动解释器失败:\(error.localizedDescription)")
        }
        let pid = process.processIdentifier

        // 超时 30s 强杀(SIGKILL,不给挂接 signal handler 的机会)。
        var timedOut = false
        if exitSem.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            timedOut = true
            kill(pid, SIGKILL)
            // 等强杀生效(terminationHandler 再 signal 一次)。
            _ = exitSem.wait(timeout: .now() + 5)
        }
        let elapsedMS = Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)

        let stdout = truncate(readTextFile(stdoutURL))
        let stderr = truncate(readTextFile(stderrURL))
        let code127 = process.isRunning ? Int32(-1) : process.terminationStatus
        // /usr/bin/env 找不到命令时退出码 127(理论上前面已拦,双保险)。
        let failure: String? = (code127 == 127)
            ? "解释器 \(interpreter) 未找到(env 退出码 127),请确认已安装。"
            : nil
        return CodeRunResult(exitCode: code127, stdout: stdout, stderr: stderr,
                             durationMS: elapsedMS, timedOut: timedOut, failureReason: failure)
    }

    /// 读输出文件头部(最多多读一点,交给 truncate 截断;非 UTF-8 字节宽容解码)。
    private static func readTextFile(_ url: URL) -> String {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: maxCaptureBytes + 4096)) ?? Data()
        return String(decoding: data ?? Data(), as: UTF8.self)
    }

    #endif

    #if os(iOS)

    // MARK: - iOS:JavaScriptCore

    /// 线程安全的输出缓冲(JSC 回调里追加,封顶即停)。
    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        private var capped = false

        func append(_ line: String) {
            lock.lock(); defer { lock.unlock() }
            guard !capped else { return }
            text += line + "\n"
            if text.utf8.count > maxCaptureBytes { capped = true }
        }

        var value: String {
            lock.lock(); defer { lock.unlock() }
            return text
        }
    }

    /// JavaScriptCore 执行:捕获 console.log / 异常;外部看门狗做超时兜底。
    /// 注:iOS 公开 SDK 没有引擎级执行时限 API(JSContextGroupSetExecutionTimeLimit 是私有头),
    /// 超时后这里只「停止等待」并标记 timedOut,失控脚本线程无法强停——输出缓冲已封顶,
    /// 设置页有「仅在信任的对话里开启」警示。
    private static func runJavaScriptCore(code: String) async -> CodeRunResult {
        /// 保证 continuation 只 resume 一次(执行线程与看门狗竞争)。
        final class ResumeOnce: @unchecked Sendable {
            private let lock = NSLock()
            private var cont: CheckedContinuation<CodeRunResult, Never>?
            init(_ c: CheckedContinuation<CodeRunResult, Never>) { cont = c }
            func resume(_ r: CodeRunResult) {
                lock.lock(); let c = cont; cont = nil; lock.unlock()
                c?.resume(returning: r)
            }
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<CodeRunResult, Never>) in
            let once = ResumeOnce(cont)
            // 看门狗:到点放弃等待,以超时结果返回。
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
                once.resume(CodeRunResult(
                    exitCode: 1, stdout: "",
                    stderr: "执行超时(\(Int(timeoutSeconds))s),已停止等待;脚本可能仍在后台运行",
                    durationMS: Int(timeoutSeconds * 1000), timedOut: true, failureReason: nil))
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let stdout = OutputBuffer()
                let stderr = OutputBuffer()

                guard let context = JSContext() else {
                    once.resume(CodeRunResult(
                        exitCode: -1, stdout: "", stderr: "", durationMS: 0, timedOut: false,
                        failureReason: "JavaScriptCore 初始化失败"))
                    return
                }

                // console.log / info / warn / error → 输出缓冲。
                let logToOut: @convention(block) () -> Void = {
                    let args = JSContext.currentArguments() ?? []
                    stdout.append(args.compactMap { ($0 as? JSValue)?.toString() }.joined(separator: " "))
                }
                let logToErr: @convention(block) () -> Void = {
                    let args = JSContext.currentArguments() ?? []
                    stderr.append(args.compactMap { ($0 as? JSValue)?.toString() }.joined(separator: " "))
                }
                let console = JSValue(newObjectIn: context)
                console?.setObject(logToOut, forKeyedSubscript: "log" as NSString)
                console?.setObject(logToOut, forKeyedSubscript: "info" as NSString)
                console?.setObject(logToOut, forKeyedSubscript: "debug" as NSString)
                console?.setObject(logToErr, forKeyedSubscript: "warn" as NSString)
                console?.setObject(logToErr, forKeyedSubscript: "error" as NSString)
                context.setObject(console, forKeyedSubscript: "console" as NSString)

                // 异常捕获(语法错误 / 运行时 throw 都会走这里)。
                final class ExceptionBox: @unchecked Sendable {
                    private let lock = NSLock()
                    private var message: String?
                    func set(_ m: String) { lock.lock(); if message == nil { message = m }; lock.unlock() }
                    var value: String? { lock.lock(); defer { lock.unlock() }; return message }
                }
                let exception = ExceptionBox()
                context.exceptionHandler = { _, exc in
                    exception.set(exc?.toString() ?? "未知异常")
                }

                let start = DispatchTime.now()
                let result = context.evaluateScript(code)
                let elapsedMS = Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)

                var out = stdout.value
                // 最后一个表达式的值(非 undefined/null 时)补进 stdout,方便模型直接拿结果。
                if let result, !result.isUndefined, !result.isNull, exception.value == nil {
                    out += "(返回值) \(result.toString() ?? "")\n"
                }
                var err = stderr.value
                var exitCode: Int32 = 0
                if let exc = exception.value {
                    err += (err.isEmpty ? "" : "\n") + "异常: \(exc)"
                    exitCode = 1
                }
                // timedOut 由看门狗负责;走到这里说明在时限内跑完了。
                once.resume(CodeRunResult(
                    exitCode: exitCode,
                    stdout: truncate(out),
                    stderr: truncate(err),
                    durationMS: elapsedMS,
                    timedOut: false,
                    failureReason: nil))
            }
        }
    }

    #endif
}
