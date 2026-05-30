import Foundation

struct SSEEvent: Sendable {
    var event: String?
    var data: String
}

/// 把 URLSession.bytes 的 AsyncBytes 解析成 SSE 事件序列。
///
/// SSE 规范:
///   - 按 \n 切行
///   - 空行表示一个事件结束
///   - 以 "data:" 开头的行是数据(同一事件多个 data 行合并,以 \n 分隔)
///   - 以 "event:" 开头的行是事件名
///   - 以 ":" 开头是注释,忽略
struct SSELineStream: AsyncSequence {
    typealias Element = SSEEvent

    let bytes: URLSession.AsyncBytes

    struct AsyncIterator: AsyncIteratorProtocol {
        var lines: URLSession.AsyncBytes.AsyncIterator
        var pendingEvent: String?
        var pendingData: [String] = []

        init(bytes: URLSession.AsyncBytes) {
            self.lines = bytes.makeAsyncIterator()
        }

        mutating func next() async throws -> SSEEvent? {
            var buffer: [UInt8] = []
            while let byte = try await lines.next() {
                if byte == 0x0A { // \n
                    let raw = String(decoding: buffer, as: UTF8.self)
                    buffer.removeAll(keepingCapacity: true)
                    if let evt = SSELineStream.consumeLine(
                        raw, pendingEvent: &pendingEvent, pendingData: &pendingData
                    ) {
                        return evt
                    }
                } else {
                    buffer.append(byte)
                }
            }
            // 流结束:把残余数据作为最后一个事件返回
            if !pendingData.isEmpty || pendingEvent != nil {
                let evt = SSEEvent(event: pendingEvent,
                                    data: pendingData.joined(separator: "\n"))
                pendingEvent = nil
                pendingData.removeAll()
                return evt
            }
            return nil
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(bytes: bytes)
    }

    /// 处理 SSE 的一行(已按 `\n` 切;`raw` 可能带尾随 `\r`)。
    /// 返回非 nil = 遇到事件边界(空行)且有累积数据 → 产出一个事件;否则更新累积状态返回 nil。
    ///
    /// 抽成纯静态函数,既给 `AsyncIterator` 复用,也给单测覆盖 **CRLF(`\r\n`)边界**:
    /// 必须先去掉行尾 `\r` 再判空,否则 Gemini 的 `\r\n\r\n` 分隔的空行("\r")识别不出,
    /// 所有 data 会累到流末尾合成一个大事件,JSON 解析失败 → 空响应(0.6.6 修过的严重 bug)。
    static func consumeLine(
        _ raw: String,
        pendingEvent: inout String?,
        pendingData: inout [String]
    ) -> SSEEvent? {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        if line.isEmpty {
            guard !pendingData.isEmpty || pendingEvent != nil else { return nil }
            let evt = SSEEvent(event: pendingEvent, data: pendingData.joined(separator: "\n"))
            pendingEvent = nil
            pendingData.removeAll()
            return evt
        }
        if line.hasPrefix(":") { return nil }       // 注释
        if let colon = line.firstIndex(of: ":") {
            let field = String(line[..<colon])
            var value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
            switch field {
            case "data": pendingData.append(value)
            case "event": pendingEvent = value
            default: break
            }
        }
        return nil
    }
}
