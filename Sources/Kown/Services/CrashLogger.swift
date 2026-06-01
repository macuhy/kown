import Foundation

/// 崩溃 / 卡死本地留痕 —— 写到 `~/.kown/logs/crashes.log`,方便出问题时直接看而不用现场抓采样。
/// - 未捕获 Objective-C 异常:`NSSetUncaughtExceptionHandler`。
/// - 致命信号(SIGABRT/SEGV/...):信号处理器写一行 + 栈,然后恢复默认处理再 raise(保留系统崩溃报告)。
/// - 主线程卡死:后台 watchdog 每隔几秒 ping 主线程,>8s 无响应记一条 HANG(就是 0.7.1 那次 14GB 空转的形态)。
///
/// 注意:信号处理器里调用 Foundation 严格说不是 async-signal-safe,但作为本地 best-effort 调试日志足够。
enum CrashLogger {
    private static var logURL: URL {
        ResponseLogger.logsDirectory.appendingPathComponent("crashes.log")
    }

    static func install() {
        NSSetUncaughtExceptionHandler { exc in
            CrashLogger.write("EXCEPTION \(exc.name.rawValue): \(exc.reason ?? "")\n"
                              + exc.callStackSymbols.joined(separator: "\n"))
        }
        for sig in [SIGABRT, SIGSEGV, SIGILL, SIGFPE, SIGBUS, SIGTRAP] {
            signal(sig) { s in
                CrashLogger.write("SIGNAL \(s)\n" + Thread.callStackSymbols.joined(separator: "\n"))
                signal(s, SIG_DFL)
                raise(s)
            }
        }
        startWatchdog()
    }

    /// 追加一条带时间戳的记录(失败静默)。
    static func write(_ body: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let entry = "==== \(f.string(from: Date())) ====\n\(body)\n\n"
        guard let data = entry.data(using: .utf8) else { return }
        let url = logURL
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 主线程卡死监测:每轮 ping 一次主线程,>8s 无响应记一条,等恢复后再继续(避免刷屏)。
    private static func startWatchdog() {
        let q = DispatchQueue(label: "app.kown.watchdog", qos: .background)
        q.async {
            while true {
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { sem.signal() }
                if sem.wait(timeout: .now() + 8) == .timedOut {
                    write("HANG: 主线程 >8s 无响应(可能布局环 / 死循环 / 主线程阻塞)")
                    sem.wait()  // 等主线程恢复,确保每次卡死只记一条
                }
                Thread.sleep(forTimeInterval: 3)
            }
        }
    }
}
