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
                    let line = String(decoding: buffer, as: UTF8.self)
                    buffer.removeAll(keepingCapacity: true)
                    // 处理一行
                    if line.isEmpty {
                        // 事件分隔
                        if !pendingData.isEmpty || pendingEvent != nil {
                            let evt = SSEEvent(event: pendingEvent,
                                                data: pendingData.joined(separator: "\n"))
                            pendingEvent = nil
                            pendingData.removeAll()
                            return evt
                        }
                        continue
                    }
                    // 去掉行尾 \r(CRLF 情况)
                    let trimmed = line.hasSuffix("\r") ? String(line.dropLast()) : line
                    if trimmed.hasPrefix(":") { continue }       // 注释
                    if let colon = trimmed.firstIndex(of: ":") {
                        let field = String(trimmed[..<colon])
                        var value = String(trimmed[trimmed.index(after: colon)...])
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
