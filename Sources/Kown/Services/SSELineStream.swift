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
                    // 关键:先去掉行尾 \r(CRLF 情况)再判空。
                    // Gemini SSE 用 \r\n\r\n 分隔事件 — 之前把 isEmpty 判断在 trim 之前,
                    // "\r" 不识别为事件边界,所有 data 累到流末尾才作为 1 个大事件出来,
                    // JSONSerialization 解 "json1\njson2..." 直接失败 → 空响应。
                    let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
                    if line.isEmpty {
                        if !pendingData.isEmpty || pendingEvent != nil {
                            let evt = SSEEvent(event: pendingEvent,
                                                data: pendingData.joined(separator: "\n"))
                            pendingEvent = nil
                            pendingData.removeAll()
                            return evt
                        }
                        continue
                    }
                    if line.hasPrefix(":") { continue }       // 注释
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
}
