import Foundation
import NaturalLanguage

/// 隐私脱敏层(PII redaction)。
///
/// 发往**云端** LLM 前,本地检测并假名化 PII —— 手机号 / 邮箱 / 身份证号 / 银行卡(信用卡)号,
/// 以及 NER 识别的人名(默认开)/ 地名 / 机构名(默认关)——
/// 用稳定、像自然语言的占位符(如「张三的电话1」式的「[电话1]」)替换原文发送;
/// 模型流式返回时再把占位符**还原**成原文展示 / 存储。每次请求一份可逆映射(`RedactionMap`)。
///
/// 设计要点:
/// - 占位符稳定 + 自然:`[人名1]` / `[电话1]` / `[邮箱1]` / `[身份证1]` / `[银行卡1]` / `[地名1]` / `[机构名1]`,
///   带方括号 + 中文类别 + 序号,既好让模型当作一个不可拆的实体保留,又不至于干扰语义。
/// - 同一原文在一次请求内复用同一个占位符(去重),还原时一一对应。
/// - 检测器:正则(身份证 / 银行卡)+ `NSDataDetector`(电话 / 邮箱 / 链接里的邮箱)+ `NLTagger` NER
///   (人名 / 地名 / 机构名;人名默认开,地名 / 机构名默认关)。
/// - **统一命中区间**:所有检测器输出同构的 `Hit`(区间 + 类别 + 来源),在**原文**上一次性收集后
///   经 `mergeHits` 合并(重叠取并集、类型正则优先、相邻同类合并),再从尾到头一次性替换 ——
///   不再串行「替换后再检测」,NER 与正则互不踩偏移。
/// - NER 前先把结构化命中**等长空格遮蔽**(`maskingRanges`):实测句中夹长邮箱 / 号码串会让
///   NLTagger 整句失灵(「…发给刘强东和马云,抄送 john.smith@example.com」一个实体都不出),
///   遮蔽后恢复;等长替换保证 NSRange 与原文对齐。
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
    /// 人名(NLTagger NER)默认 **开**:实测常见中文 / 英文姓名识别可用、纯叙述句几乎零误报
    ///   (详见 `detectEntities` 注释);误中也只是占位符替换、回流自动还原,代价低。
    static let nameKey    = "kown.privacy.piiRedaction.name"
    /// 地名 / 机构名(NLTagger NER)默认 **关**:地名多数场景不敏感,中文机构名漏报多,opt-in。
    static let placeKey   = "kown.privacy.piiRedaction.place"
    static let orgKey     = "kown.privacy.piiRedaction.org"

    struct Settings: Sendable {
        var enabled: Bool
        var phone: Bool
        var email: Bool
        var idCard: Bool
        var bank: Bool
        var name: Bool
        /// 地名 / 机构名(NER 类别,后加):带默认值,老构造点不传时视为关闭。
        var place: Bool = false
        var org: Bool = false

        /// 任一分类开着才有脱敏意义。
        var anyCategoryOn: Bool { phone || email || idCard || bank || name || place || org }
        var active: Bool { enabled && anyCategoryOn }
        /// 任一 NER 类别开着才需要跑 NLTagger。
        var anyNEROn: Bool { name || place || org }
    }

    /// 从 UserDefaults 读当前设置(分类开关缺省视为开;NER 类别里人名缺省开,地名 / 机构名缺省关)。
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
            name:    flag(nameKey,   default: true),
            place:   flag(placeKey,  default: false),
            org:     flag(orgKey,    default: false)
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

    enum Category: CaseIterable, Sendable {
        case name, phone, email, idCard, bank, place, org
        var label: String {
            switch self {
            case .name:   return "人名"
            case .phone:  return "电话"
            case .email:  return "邮箱"
            case .idCard: return "身份证"
            case .bank:   return "银行卡"
            case .place:  return "地名"
            case .org:    return "机构名"
            }
        }
    }

    // MARK: - 命中区间(正则 / NER 同构)

    /// 一次检测命中:区间 + 类别 + 来源。所有检测器(正则 / NSDataDetector / NLTagger)的输出
    /// 统一成这个形态后交给 `mergeHits` 合并,再一次性替换。
    struct Hit: Equatable, Sendable {
        enum Source: Equatable, Sendable {
            /// 结构化检测(正则 / NSDataDetector):更确定,合并时类型优先。
            case regex
            /// NLTagger 命名实体识别:精度不如正则,合并时让位。
            case ner
        }
        var range: NSRange
        var category: Category
        var source: Source
    }

    // MARK: - 出站:脱敏

    /// 把文本里的 PII 替换成占位符,返回(脱敏后文本, 映射)。`map` 可传入已有映射以跨多段(prompt/system/历史)复用同一份。
    /// settings 不 active 时原样返回。
    static func redact(_ text: String,
                       settings: Settings,
                       map: RedactionMap = RedactionMap()) -> (text: String, map: RedactionMap) {
        guard settings.active, !text.isEmpty else { return (text, map) }

        var resultMap = map
        // 类别计数器随映射走(已有映射时从已分配数接续,避免占位符重号)。
        var counters: [Category: Int] = [:]
        for cat in Category.allCases {
            counters[cat] = resultMap.placeholderToOriginal.keys.filter { $0.hasPrefix("[\(cat.label)") }.count
        }

        // ① 结构化检测(正则 / NSDataDetector),全部在**原文**上找区间,互相不踩偏移。
        var hits: [Hit] = []
        if settings.idCard { hits += detectIDCards(text).map   { Hit(range: $0, category: .idCard, source: .regex) } }
        if settings.bank   { hits += detectBankCards(text).map { Hit(range: $0, category: .bank,   source: .regex) } }
        if settings.email  { hits += detectEmails(text).map    { Hit(range: $0, category: .email,  source: .regex) } }
        if settings.phone  { hits += detectPhones(text).map    { Hit(range: $0, category: .phone,  source: .regex) } }

        // ② NER(人名 / 地名 / 机构名)叠加:先把结构化命中等长空格遮蔽再喂 NLTagger
        //   (长邮箱 / 号码串会让 NLTagger 整句失灵;等长遮蔽保证区间与原文对齐)。
        if settings.anyNEROn {
            let nerInput = hits.isEmpty ? text : maskingRanges(hits.map(\.range), in: text)
            hits += detectEntities(nerInput, name: settings.name, place: settings.place, org: settings.org)
        }

        // ③ 区间合并(重叠取并集、类型正则优先、相邻同类合并)→ ④ 一次性替换。
        let out = replaceHits(in: text, hits: mergeHits(hits), map: &resultMap, counters: &counters)
        return (out, resultMap)
    }

    /// 把合并后的命中替换成占位符:**升序**分配编号(文中第一个电话是「[电话1]」,同一原文复用同一占位符),
    /// 再从尾往前替换,避免前面的替换打乱后面的偏移。
    private static func replaceHits(in text: String,
                                    hits: [Hit],
                                    map: inout RedactionMap,
                                    counters: inout [Category: Int]) -> String {
        guard !hits.isEmpty else { return text }
        let ns = text as NSString
        let valid = hits
            .filter { $0.range.location != NSNotFound && NSMaxRange($0.range) <= ns.length }
            .sorted { $0.range.location < $1.range.location }
        // 先按出现顺序分配占位符。
        var replacements: [(NSRange, String)] = []
        for hit in valid {
            let original = ns.substring(with: hit.range)
            var cnt = counters[hit.category] ?? 0
            let ph = map.placeholder(for: original, category: hit.category, counter: &cnt)
            counters[hit.category] = cnt
            replacements.append((hit.range, ph))
        }
        // 从尾往前应用替换。
        let mutable = NSMutableString(string: text)
        for (r, ph) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
            mutable.replaceCharacters(in: r, with: ph)
        }
        return mutable as String
    }

    /// 把 ranges 全部替换成**等长**空格(NSRange.length 是 UTF-16 单元数,空格恰好 1 单元 →
    /// 文本总长不变,后续在遮蔽文本上算出的 NSRange 与原文一一对齐)。NER 前用来挡掉结构化命中的干扰。
    private static func maskingRanges(_ ranges: [NSRange], in text: String) -> String {
        let ns = text as NSString
        let mutable = NSMutableString(string: text)
        for r in ranges.sorted(by: { $0.location > $1.location })
        where r.location != NSNotFound && r.length > 0 && NSMaxRange(r) <= ns.length {
            mutable.replaceCharacters(in: r, with: String(repeating: " ", count: r.length))
        }
        return mutable as String
    }

    // MARK: - 区间合并

    /// 把正则 + NER 的命中合并成互不重叠的最终区间:
    /// - **重叠(含嵌套)取并集,类型正则优先**(正则更确定):NER 命中撞上正则命中 → 区间并集、
    ///   类别保留正则的;一个 NER 跨过多个正则命中时把它们桥接成一个(类别取其中结构化优先级最高者)。
    /// - 正则 × 正则重叠:按结构化优先级(身份证 > 银行卡 > 邮箱 > 电话,即旧串行管线的替换顺序)
    ///   保留强者、**丢弃**弱者(不扩区间,保持旧语义)。
    /// - NER × NER 重叠:并集,类别取更长的那个(更长 = 上下文更完整)。
    /// - **相邻同类合并**(前一个结束位置 == 后一个起始位置):主要服务 NLTagger 偶尔把中文姓名
    ///   拆成相邻单字 token 的情况。
    /// 返回按 location 升序、互不重叠的命中。
    static func mergeHits(_ hits: [Hit]) -> [Hit] {
        let valid = hits.filter { $0.range.location != NSNotFound && $0.range.length > 0 }
        guard valid.count > 1 else { return valid }

        // 处理顺序 = 优先级:正则按结构化强度,NER 殿后;同优先级先长后短(长的吸收短的)、再按位置稳定排序。
        let ordered = valid.sorted { a, b in
            let (pa, pb) = (priority(a), priority(b))
            if pa != pb { return pa < pb }
            if a.range.length != b.range.length { return a.range.length > b.range.length }
            return a.range.location < b.range.location
        }

        var result: [Hit] = []
        for hit in ordered {
            // result 内部互不重叠,且插入序 = 优先级序(索引小者更强)。
            let overlapping = result.indices.filter { NSIntersectionRange(result[$0].range, hit.range).length > 0 }
            guard let strongest = overlapping.first else {
                result.append(hit)
                continue
            }
            // 正则命中撞上更强的已选命中(只可能是正则,NER 此时还没入场)→ 丢弃,不扩区间。
            guard hit.source == .ner else { continue }
            // NER 命中:并入最强的重叠者(类型保留对方的 → 正则优先 / 更长 NER 优先),
            // 被同一个 NER 桥接起来的其余重叠者一并吸收。并集 = 精确覆盖(都与 hit 相交,连续无空洞),
            // 因此不会与 result 里其它命中产生新重叠。
            var union = hit.range
            for idx in overlapping { union = NSUnionRange(union, result[idx].range) }
            result[strongest].range = union
            for idx in overlapping.dropFirst().reversed() { result.remove(at: idx) }
        }

        // 相邻同类合并(按位置升序扫一遍)。
        var sorted = result.sorted { $0.range.location < $1.range.location }
        var i = 0
        while i + 1 < sorted.count {
            let cur = sorted[i], next = sorted[i + 1]
            if cur.category == next.category, NSMaxRange(cur.range) == next.range.location {
                sorted[i].range = NSUnionRange(cur.range, next.range)
                if next.source == .regex { sorted[i].source = .regex }
                sorted.remove(at: i + 1)
            } else {
                i += 1
            }
        }
        return sorted
    }

    /// 合并时的处理优先级(数值小者先安放、更强):正则按旧串行管线的替换顺序,NER 殿后。
    private static func priority(_ hit: Hit) -> Int {
        guard hit.source == .regex else { return 10 }
        switch hit.category {
        case .idCard: return 0
        case .bank:   return 1
        case .email:  return 2
        case .phone:  return 3
        default:      return 4   // 正则源理论上不出 NER 类别,兜底排在结构化之后、NER 之前
        }
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

    /// 命名实体识别(NLTagger `.nameType`):人名 / 地名 / 机构名,按开关取舍,输出与正则同构的 `Hit`。
    ///
    /// 实测(macOS 15,2026-06):
    /// - **人名**:虽然 `availableTagSchemes` 没把 NameType 列进 zh-Hans,但中文实际可用且效果好 ——
    ///   常见姓名(张伟 / 王芳)、复姓(诸葛青云 / 欧阳娜娜)、称呼式(老王 / 小张 / 陈经理)、
    ///   句首人名、中英混排(王小明 + David Chen)全部命中;纯叙述句 / 技术问句零误报,
    ///   品牌词(苹果手机 / 微信)不误标 → 默认开。
    /// - **地名**:北京 / 上海 / 深圳 能识,但会把动词吃进去(「飞上海」整体标成地名);
    /// - **机构名**:阿里巴巴 能识,腾讯 / 字节跳动 漏报,且有「上海开新办公室」式整段误报
    ///   → 地名 / 机构名误报率高,默认关(opt-in)。
    /// - 句中夹长邮箱 / 号码串会让整句 NER 失灵,调用前先 `maskingRanges` 等长遮蔽(见 `redact`)。
    ///
    /// `.joinNames` 把多 token 姓名(John Smith)合成一个命中;NLTagger 偶尔仍把中文姓名拆成
    /// 相邻单字 token,交给 `mergeHits` 的相邻同类合并兜底。
    static func detectEntities(_ text: String, name: Bool, place: Bool, org: Bool) -> [Hit] {
        guard name || place || org, !text.isEmpty else { return [] }
        var hits: [Hit] = []
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        let nsLength = (text as NSString).length
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word, scheme: .nameType, options: options) { tag, tokenRange in
            let category: Category?
            switch tag {
            case .personalName?:     category = name  ? .name  : nil
            case .placeName?:        category = place ? .place : nil
            case .organizationName?: category = org   ? .org   : nil
            default:                 category = nil
            }
            if let category {
                let ns = NSRange(tokenRange, in: text)
                if ns.location != NSNotFound && ns.length > 0 && NSMaxRange(ns) <= nsLength {
                    hits.append(Hit(range: ns, category: category, source: .ner))
                }
            }
            return true
        }
        return hits
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
