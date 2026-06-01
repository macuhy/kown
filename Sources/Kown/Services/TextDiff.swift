import Foundation

/// 行级 diff(LCS)。纯函数,供 workspace 改动的「查看 diff」用,也方便单测。
enum TextDiff {
    enum Kind: Sendable, Equatable {
        case equal
        case insert   // 新增(只在 new 里)
        case delete   // 删除(只在 old 里)
    }

    struct Line: Identifiable, Sendable, Equatable {
        let id: Int
        let kind: Kind
        let text: String
    }

    /// 计算 old → new 的行级 diff。
    static func diff(old: String, new: String) -> [Line] {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let b = new.isEmpty ? [] : new.components(separatedBy: "\n")
        let n = a.count, m = b.count

        // LCS DP 表(行数较多时也只是 O(n*m),workspace 文件一般可控)。
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        var out: [Line] = []
        var id = 0
        var i = 0, j = 0
        func emit(_ kind: Kind, _ text: String) { out.append(Line(id: id, kind: kind, text: text)); id += 1 }
        while i < n && j < m {
            if a[i] == b[j] {
                emit(.equal, a[i]); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                emit(.delete, a[i]); i += 1
            } else {
                emit(.insert, b[j]); j += 1
            }
        }
        while i < n { emit(.delete, a[i]); i += 1 }
        while j < m { emit(.insert, b[j]); j += 1 }
        return out
    }

    /// 统计 (新增行数, 删除行数)。
    static func stats(_ lines: [Line]) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for l in lines {
            if l.kind == .insert { added += 1 }
            else if l.kind == .delete { removed += 1 }
        }
        return (added, removed)
    }
}
