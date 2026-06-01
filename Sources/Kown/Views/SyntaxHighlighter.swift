import SwiftUI

/// 轻量原生代码高亮:正则把注释 / 字符串 / 数字 / 关键字着色成 `AttributedString`。
/// 不引第三方(避免带 JS 资源 + Bundle.module 风险),覆盖常见语言;未知语言回退到
/// 「字符串 + 注释 + 数字」通用高亮,关键字留空。
@MainActor
enum SyntaxHighlighter {
    /// 超过此长度的代码块不高亮(直接返回纯文本),避免大块正则开销。
    private static let maxChars = 20_000

    static func highlight(_ code: String, language: String?) -> AttributedString {
        guard code.count <= maxChars else { return AttributedString(code) }
        let spec = LangSpec.forLanguage(language)
        guard let regex = spec.regex else { return AttributedString(code) }

        let ns = code as NSString
        var result = AttributedString()
        var last = 0
        regex.enumerateMatches(in: code, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            // 未匹配的间隙保持默认色
            if match.range.location > last {
                result.append(AttributedString(ns.substring(with: NSRange(location: last, length: match.range.location - last))))
            }
            let token = ns.substring(with: match.range)
            var seg = AttributedString(token)
            seg.foregroundColor = color(for: match, spec: spec)
            result.append(seg)
            last = match.range.location + match.range.length
        }
        if last < ns.length {
            result.append(AttributedString(ns.substring(from: last)))
        }
        return result
    }

    private static func color(for match: NSTextCheckingResult, spec: LangSpec) -> Color {
        // 命中的组决定颜色:1=comment 2=string 3=number 4=keyword
        if match.range(at: 1).location != NSNotFound { return Palette.comment }
        if match.range(at: 2).location != NSNotFound { return Palette.string }
        if match.range(at: 3).location != NSNotFound { return Palette.number }
        if match.range(at: 4).location != NSNotFound { return Palette.keyword }
        return Palette.plain
    }

    enum Palette {
        static let plain = Color.primary
        static let comment = Color.secondary
        static let string = Color(red: 0.83, green: 0.37, blue: 0.33)
        static let number = Color(red: 0.85, green: 0.55, blue: 0.20)
        static let keyword = Color(red: 0.61, green: 0.38, blue: 0.82)
    }
}

/// 一门语言的高亮规格 —— 行注释前缀 + 关键字集,编译成一个组合正则(组顺序固定)。
private struct LangSpec {
    let lineComments: [String]   // 如 ["//"] / ["#"]
    let keywords: [String]
    let regex: NSRegularExpression?

    init(lineComments: [String], keywords: [String]) {
        self.lineComments = lineComments
        self.keywords = keywords
        self.regex = LangSpec.compile(lineComments: lineComments, keywords: keywords)
    }

    /// 组合正则:组1 注释 | 组2 字符串 | 组3 数字 | 组4 关键字。
    /// 注释 / 字符串靠前 → 它们整体被吃掉,内部的"关键字 / 数字"不会被二次着色。
    private static func compile(lineComments: [String], keywords: [String]) -> NSRegularExpression? {
        var alts: [String] = []
        // 1) 注释:块注释 + 各行注释前缀
        var commentAlts: [String] = ["/\\*[\\s\\S]*?\\*/"]
        for c in lineComments {
            commentAlts.append(NSRegularExpression.escapedPattern(for: c) + "[^\\n]*")
        }
        alts.append("(" + commentAlts.joined(separator: "|") + ")")
        // 2) 字符串:双引号 / 单引号 / 反引号,允许转义
        alts.append("(\"(?:\\\\.|[^\"\\\\\\n])*\"|'(?:\\\\.|[^'\\\\\\n])*'|`(?:\\\\.|[^`\\\\])*`)")
        // 3) 数字
        alts.append("(\\b\\d[\\d_]*(?:\\.\\d+)?\\b)")
        // 4) 关键字(可空)
        if keywords.isEmpty {
            alts.append("()")
        } else {
            let kw = keywords.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            alts.append("(\\b(?:\(kw))\\b)")
        }
        let pattern = alts.joined(separator: "|")
        return try? NSRegularExpression(pattern: pattern, options: [])
    }

    static func forLanguage(_ raw: String?) -> LangSpec {
        let lang = (raw ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        switch lang {
        case "swift":
            return LangSpec(lineComments: ["//"], keywords: [
                "func","let","var","if","else","guard","return","struct","class","enum","protocol","extension",
                "import","for","in","while","switch","case","default","break","continue","do","try","catch","throw",
                "throws","async","await","actor","init","self","Self","nil","true","false","public","private","internal",
                "fileprivate","static","final","lazy","weak","unowned","some","any","where","as","is","defer","mutating"])
        case "js","javascript","ts","typescript","tsx","jsx","mjs","cjs":
            return LangSpec(lineComments: ["//"], keywords: [
                "function","let","const","var","if","else","return","for","while","switch","case","default","break",
                "continue","class","extends","new","this","import","export","from","async","await","try","catch","finally",
                "throw","typeof","instanceof","null","undefined","true","false","yield","interface","type","enum","public",
                "private","readonly","of","in","do","void"])
        case "python","py":
            return LangSpec(lineComments: ["#"], keywords: [
                "def","class","if","elif","else","return","for","while","import","from","as","try","except","finally",
                "raise","with","lambda","yield","async","await","pass","break","continue","global","nonlocal","in","is",
                "not","and","or","None","True","False","self","del","assert"])
        case "go","golang":
            return LangSpec(lineComments: ["//"], keywords: [
                "func","var","const","if","else","return","for","range","switch","case","default","break","continue",
                "type","struct","interface","map","chan","go","defer","package","import","nil","true","false","select",
                "fallthrough","goto"])
        case "rust","rs":
            return LangSpec(lineComments: ["//"], keywords: [
                "fn","let","mut","if","else","return","for","while","loop","match","struct","enum","trait","impl","pub",
                "use","mod","const","static","self","Self","crate","super","async","await","move","ref","where","as",
                "true","false","Some","None","Ok","Err"])
        case "java","kotlin","kt":
            return LangSpec(lineComments: ["//"], keywords: [
                "public","private","protected","class","interface","extends","implements","return","if","else","for",
                "while","switch","case","default","break","continue","new","this","super","static","final","void","import",
                "package","try","catch","finally","throw","throws","null","true","false","val","var","fun","when","object"])
        case "c","cpp","c++","h","hpp","cc","objc","objective-c","m","mm":
            return LangSpec(lineComments: ["//"], keywords: [
                "int","char","float","double","long","short","unsigned","signed","void","bool","struct","enum","union",
                "if","else","for","while","switch","case","default","break","continue","return","const","static","typedef",
                "sizeof","include","define","class","public","private","protected","new","delete","nullptr","true","false","auto"])
        case "bash","sh","shell","zsh","fish":
            return LangSpec(lineComments: ["#"], keywords: [
                "if","then","else","elif","fi","for","while","do","done","case","esac","function","return","in","export",
                "local","echo","cd","exit","source"])
        case "json":
            return LangSpec(lineComments: [], keywords: ["true","false","null"])
        case "yaml","yml","toml","ini","conf":
            return LangSpec(lineComments: ["#"], keywords: ["true","false","null"])
        case "ruby","rb":
            return LangSpec(lineComments: ["#"], keywords: [
                "def","end","class","module","if","elsif","else","unless","return","do","while","for","in","case","when",
                "then","begin","rescue","ensure","yield","nil","true","false","self","require","attr_accessor","puts"])
        default:
            // 未知语言:通用注释前缀 + 无关键字
            return LangSpec(lineComments: ["//", "#"], keywords: [])
        }
    }
}
