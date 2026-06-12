import Foundation
import NaturalLanguage

/// 隐私脱敏层(PII redaction)。
///
/// 发往**云端** LLM 前,本地检测并假名化 PII —— 手机号 / 邮箱 / 身份证号 / 银行卡(信用卡)号,
/// 可选人名 —— 用稳定、像自然语言的占位符(如「张三的电话1」式的「[电话1]」)替换原文发送;
/// 模型流式返回时再把占位符**还原**成原文展示 / 存储。每次请求一份可逆映射(`RedactionMap`)。
///
/// 设计要点:
/// - 占位符稳定 + 自然:`[人名1]` / `[电话1]` / `[邮箱1]` / `[身份证1]` / `[银行卡1]`,
///   带方括号 + 中文类别 + 序号,既好让模型当作一个不可拆的实体保留,又不至于干扰语义。
/// - 同一原文在一次请求内复用同一个占位符(去重),还原时一一对应。
/// - 检测器:正则(身份证 / 银行卡)+ `NSDataDetector`(电话 / 邮箱 / 链接里的邮箱)+ `NLTagger`(人名,可选)。
/// - **本地 provider(Ollama / OpenAICompatible 指向 localhost / CLI)跳过脱敏**:数据没出本机,
///   假名化只会徒增模型负担。判断见 `isLocalProvider(_:)`。
/// - 还原要处理「占位符被拆在多个流式 chunk 边界」的情况:用 `StreamingRestorer` 做缓冲,
///   占位符未完整出现前先 hold 住尾巴,凑齐再吐。
///
/// 仅依赖 Foundation + NaturalLanguage(NSDataDetector / NLTagger 两端都有),零平台分支。
enum PIIRedactor {

    // MARK: - 设置(读 UserDefaults,与 PrivacySettingsView 的 @AppStorage 同 key)

    /// 总开关 key。默认 **关闭**(隐私功能 opt-in)。
    static let enabledKey = "kown.privacy.piiRedaction.enabled"
    /// 分类开关 key(默认开;总开关开时这些才生效)。
    static let phoneKey   = "kown.privacy.piiRedaction.phone"
    static let emailKey   = "kown.privacy.piiRedaction.email"
    static let idCardKey  = "kown.privacy.piiRedaction.idcard"
    static let bankKey    = "kown.privacy.piiRedaction.bank"
    /// 人名脱敏默认 **关闭**(NLTagger 误报率比正则高,opt-in)。
    static let nameKey    = "kown.privacy.piiRedaction.name"

    struct Settings: Sendable {
        var enabled: Bool
        var phone: Bool
        var email: Bool
        var idCard: Bool
        var bank: Bool
        var name: Bool

        /// 任一分类开着才有脱敏意义。
        var anyCategoryOn: Bool { phone || email || idCard || bank || name }
        var active: Bool { enabled && anyCategoryOn }
    }

    /// 从 UserDefaults 读当前设置(分类开关缺省视为开,人名缺省为关)。
    @MainActor
    static func currentSettings() -> Settings {
        let ud = UserDefaults.standard
        func flag(_ key: String, default def: Bool) -> Bool {
            (ud.object(forKey: key) as? Bool) ?? def
        }
        return Settings(
            enabled: ud.bool(forKey: enabledKey),     // 默认 false
            phone:   flag(phoneKey,  default: true),
            email:   flag(emailKey,  default: true),
            idCard:  flag(idCardKey, default: true),
            bank:    flag(bankKey,   default: true),
            name:    flag(nameKey,   default: false)
        )
    }

    // MARK: - 本地 provider 判断(本地则跳过脱敏)

    /// provider 是否「本地」:CLI(本机子进程)、Apple 本地模型(端侧推理)、Ollama(vendor 标记)、
    /// 或 baseURL 指向本机回环地址。本地 = 数据不出本机,无需脱敏。
    static func isLocalProvider(_ config: ProviderConfig) -> Bool {
        if config.kind.isCLI || config.kind.isAppleFM { return true }
        if config.vendor?.lowercased() == "ollama" { return true }
        return isLocalBaseURL(config.baseURL)
    }

    /// baseURL 的 host 是否为本机回环 / .local / 私网常见自托管地址。
    static func isLocalBaseURL(_ baseURL: String) -> Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else {
            // 没有 scheme 时 URL.host 会是 nil,退而在字符串里找
            let s = baseURL.lowercased()
            return s.contains("localhost") || s.contains("127.0.0.1") || s.contains("[::1]")
        }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }
        if host.hasSuffix(".local") { return true }
        // 私网 10.x / 192.168.x / 172.16–31.x(自托管常用)。
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        return false
    }

    // MARK: - 可逆映射

    /// 一次请求的脱敏映射:占位符 ↔ 原文。`placeholderToOriginal` 用于还原(流式 / 整段)。
    struct RedactionMap: Sendable {
        /// 占位符 → 原文。
        private(set) var placeholderToOriginal: [String: String] = [:]
        /// 原文 → 占位符(去重:同一原文复用同一占位符)。
        private(set) var originalToPlaceholder: [String: String] = [:]

        var isEmpty: Bool { placeholderToOriginal.isEmpty }

        /// 登记一个原文,返回(并在首次出现时分配)其占位符。`counter` 为该类别已分配数。
        mutating func placeholder(for original: String, category: Category, counter: inout Int) -> String {
            if let existing = originalToPlaceholder[original] { return existing }
            counter += 1
            let ph = "[\(category.label)\(counter)]"
            originalToPlaceholder[original] = ph
            placeholderToOriginal[ph] = original
            return ph
        }
    }

    enum Category: CaseIterable {
        case name, phone, email, idCard, bank
        var label: String {
            switch self {
            case .name:   return "人名"
            case .phone:  return "电话"
            case .email:  return "邮箱"
            case .idCard: return "身份证"
            case .bank:   return "银行卡"
            }
        }
    }

    // MARK: - 出站:脱敏

    /// 把文本里的 PII 替换成占位符,返回(脱敏后文本, 映射)。`map` 可传入已有映射以跨多段(prompt/system/历史)复用同一份。
    /// settings 不 active 时原样返回。
    static func redact(_ text: String,
                       settings: Settings,
                       map: RedactionMap = RedactionMap()) -> (text: String, map: RedactionMap) {
        guard settings.active, !text.isEmpty else { return (text, map) }

        var working = text
        var resultMap = map
        // 类别计数器随映射走(已有映射时从已分配数接续,避免占位符重号)。
        var counters: [Category: Int] = [:]
        for cat in Category.allCases {
            counters[cat] = resultMap.placeholderToOriginal.keys.filter { $0.hasPrefix("[\(cat.label)") }.count
        }

        // 顺序:先结构化(身份证 / 银行卡 / 邮箱 / 电话),最后人名。
        // 先长后短,避免银行卡号里的子串被电话规则先吃掉。
        if settings.idCard {
            working = replaceMatches(in: working, ranges: detectIDCards(working),
                                     category: .idCard, map: &resultMap, counters: &counters)
        }
        if settings.bank {
            working = replaceMatches(in: working, ranges: detectBankCards(working),
                                     category: .bank, map: &resultMap, counters: &counters)
        }
        if settings.email {
            working = replaceMatches(in: working, ranges: detectEmails(working),
                                     category: .email, map: &resultMap, counters: &counters)
        }
        if settings.phone {
            working = replaceMatches(in: working, ranges: detectPhones(working),
                                     category: .phone, map: &resultMap, counters: &counters)
        }
        if settings.name {
            working = replaceMatches(in: working, ranges: detectNames(working),
                                     category: .name, map: &resultMap, counters: &counters)
        }
        return (working, resultMap)
    }

    /// 把一批(已找到的)NSRange 从后往前替换成占位符,避免前面的替换打乱后面的偏移。
    private static func replaceMatches(in text: String,
                                       ranges: [NSRange],
                                       category: Category,
                                       map: inout RedactionMap,
                                       counters: inout [Category: Int]) -> String {
        guard !ranges.isEmpty else { return text }
        let ns = text as NSString
        // 去重 + 按 location 降序,从尾部往前替换。
        let sorted = ranges
            .filter { $0.location != NSNotFound && NSMaxRange($0) <= ns.length }
            .sorted { $0.location > $1.location }
        let mutable = NSMutableString(string: text)
        var cnt = counters[category] ?? 0
        for r in sorted {
            let original = ns.substring(with: r)
            let ph = map.placeholder(for: original, category: category, counter: &cnt)
            mutable.replaceCharacters(in: r, with: ph)
        }
        counters[category] = cnt
        return mutable as String
    }

    // MARK: - 检测器

    private static func detectWithDataDetector(_ text: String, type: NSTextCheckingResult.CheckingType,
                                               filter: (NSTextCheckingResult) -> Bool) -> [NSRange] {
        guard let detector = try? NSDataDetector(types: type.rawValue) else { return [] }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return detector.matches(in: text, options: [], range: range)
            .filter(filter)
            .map { $0.range }
    }

    static func detectEmails(_ text: String) -> [NSRange] {
        // NSDataDetector 的 .link 会把 mailto: 链接也算上;取 url.scheme == mailto 的,落到邮箱地址范围。
        var ranges: [NSRange] = []
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let full = NSRange(location: 0, length: (text as NSString).length)
            for m in detector.matches(in: text, options: [], range: full) {
                if let url = m.url, url.scheme?.lowercased() == "mailto" {
                    ranges.append(m.range)
                }
            }
        }
        // 兜底正则(裸邮箱地址,NSDataDetector 偶尔不识别没 mailto 前缀的)。
        ranges.append(contentsOf: regexRanges(in: text,
            pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#))
        return dedupeRanges(ranges)
    }

    static func detectPhones(_ text: String) -> [NSRange] {
        var ranges = detectWithDataDetector(text, type: .phoneNumber) { _ in true }
        // 兜底:中国大陆手机号(1[3-9] 开头 11 位),NSDataDetector 对纯数字串识别不稳。
        ranges.append(contentsOf: regexRanges(in: text, pattern: #"(?<!\d)1[3-9]\d{9}(?!\d)"#))
        return dedupeRanges(ranges)
    }

    /// 中国大陆居民身份证:18 位(末位可为 X),或老式 15 位纯数字。
    static func detectIDCards(_ text: String) -> [NSRange] {
        let p18 = #"(?<![0-9Xx])\d{17}[0-9Xx](?![0-9Xx])"#
        let p15 = #"(?<!\d)\d{15}(?!\d)"#
        return dedupeRanges(regexRanges(in: text, pattern: p18) + regexRanges(in: text, pattern: p15))
    }

    /// 银行卡 / 信用卡:13–19 位数字,允许中间用空格 / 连字符分组。用 Luhn 校验过滤误报。
    static func detectBankCards(_ text: String) -> [NSRange] {
        let pattern = #"(?<![\d\-])(?:\d[ \-]?){12,18}\d(?![\d\-])"#
        let candidates = regexRanges(in: text, pattern: pattern)
        let ns = text as NSString
        return candidates.filter { r in
            let raw = ns.substring(with: r)
            let digits = raw.filter { $0.isNumber }
            guard (13...19).contains(digits.count) else { return false }
            return luhnValid(digits)
        }
    }

    /// 人名(NLTagger 命名实体识别;中英文都能识)。仅取 .personalName。
    static func detectNames(_ text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        let nsText = text as NSString
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word, scheme: .nameType, options: options) { tag, tokenRange in
            if tag == .personalName {
                let ns = NSRange(tokenRange, in: text)
                if ns.location != NSNotFound && NSMaxRange(ns) <= nsText.length {
                    ranges.append(ns)
                }
            }
            return true
        }
        return dedupeRanges(ranges)
    }

    // MARK: - 工具

    private static func regexRanges(in text: String, pattern: String) -> [NSRange] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return re.matches(in: text, options: [], range: range).map { $0.range }
    }

    /// 去重 + 去掉被另一个更大 range 完全包含的子 range(避免重复 / 嵌套替换)。
    private static func dedupeRanges(_ ranges: [NSRange]) -> [NSRange] {
        let valid = ranges.filter { $0.location != NSNotFound && $0.length > 0 }
        var result: [NSRange] = []
        // 先按长度降序,大的优先占位;后来的若与已选 range 有重叠则丢弃。
        for r in valid.sorted(by: { $0.length > $1.length }) {
            let overlaps = result.contains { NSIntersectionRange($0, r).length > 0 }
            if !overlaps { result.append(r) }
        }
        return result
    }

    /// Luhn 校验(银行卡 / 信用卡通用)。
    private static func luhnValid(_ digits: String) -> Bool {
        var sum = 0
        var alternate = false
        for ch in digits.reversed() {
            guard let d = ch.wholeNumberValue else { return false }
            var n = d
            if alternate {
                n *= 2
                if n > 9 { n -= 9 }
            }
            sum += n
            alternate.toggle()
        }
        return sum % 10 == 0
    }

    // MARK: - 入站:整段还原

    /// 把整段文本里的占位符还原成原文(非流式路径用,如重试 / 历史)。
    static func restore(_ text: String, map: RedactionMap) -> String {
        guard !map.isEmpty, !text.isEmpty else { return text }
        var out = text
        // 长占位符先替换,避免 "[电话1]" 被 "[电话11]" 的子串干扰(虽带方括号一般不撞,稳妥起见排序)。
        for (ph, original) in map.placeholderToOriginal.sorted(by: { $0.key.count > $1.key.count }) {
            out = out.replacingOccurrences(of: ph, with: original)
        }
        return out
    }
}

// MARK: - 流式还原(处理占位符跨 chunk 边界)

extension PIIRedactor {
    /// 流式占位符还原器:逐 chunk 喂入,已确定不可能再属于某占位符前缀的部分立刻吐出,
    /// 末尾可能是「半个占位符」(如收到 "...[电" 还没等到 "话1]")时先 hold 住,等后续 chunk 凑齐再还原。
    /// 流结束调用 `flush()` 把残留(可能是未闭合的半截)原样吐出。
    ///
    /// `@MainActor` 不是必须的 —— 设计成值语义的引用类型,在 runOne 的流循环里本地持有即可。
    final class StreamingRestorer {
        private let map: RedactionMap
        private var pending: String = ""   // 可能含半截占位符的尾巴
        private let maxPlaceholderLen: Int

        init(map: RedactionMap) {
            self.map = map
            // 占位符最大长度:用于判断尾巴 hold 多少。取已知占位符里最长的 + 余量。
            let longest = map.placeholderToOriginal.keys.map { $0.count }.max() ?? 0
            self.maxPlaceholderLen = max(longest, 16)
        }

        /// 喂入一个 chunk,返回**可安全展示**的已还原文本(可能为空 —— 全被 hold 当作半截占位符)。
        func push(_ chunk: String) -> String {
            guard !map.isEmpty else { return chunk }   // 没映射 → 直通
            pending += chunk

            // 先把 pending 里所有「完整出现」的占位符还原掉。
            var restored = PIIRedactor.restore(pending, map: map)

            // restored 末尾可能是「半个占位符」:如果末尾存在一个「'[' 起头、且能作为某占位符前缀」的悬挂片段,
            // 就把它留到 pending,等下一个 chunk;其余安全吐出。
            let holdLen = danglingPrefixLength(in: restored)
            if holdLen > 0 {
                let splitIdx = restored.index(restored.endIndex, offsetBy: -holdLen)
                pending = String(restored[splitIdx...])
                restored = String(restored[..<splitIdx])
            } else {
                pending = ""
            }
            return restored
        }

        /// 流结束:把残留(含可能未闭合的半截)原样吐出。
        func flush() -> String {
            let out = pending
            pending = ""
            return out
        }

        /// 返回 text 末尾「可能是某占位符前缀」的悬挂长度(0 = 末尾安全,可全部吐出)。
        /// 规则:从最后一个 '[' 开始到结尾的子串,如果不含 ']'(还没闭合)且是某已知占位符的前缀,就 hold。
        /// 为防极端情况(一个孤立 '[' 永远 hold),超过 maxPlaceholderLen 就不再 hold。
        private func danglingPrefixLength(in text: String) -> Int {
            guard let lastOpen = text.lastIndex(of: "[") else { return 0 }
            let tail = text[lastOpen...]
            // 已闭合(含 ']')→ 不是半截,restore 已处理过,无需 hold。
            if tail.contains("]") { return 0 }
            // 太长 → 不可能是占位符(占位符都短),放行避免无限 hold。
            if tail.count > maxPlaceholderLen { return 0 }
            // 是某占位符的前缀才 hold。
            let tailStr = String(tail)
            let isPrefix = map.placeholderToOriginal.keys.contains { $0.hasPrefix(tailStr) }
            return isPrefix ? tail.count : 0
        }
    }
}
