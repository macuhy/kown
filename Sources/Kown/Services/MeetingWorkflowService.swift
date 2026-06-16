import Foundation

/// Offline-first generator for Meeting Close-loop 2.0.
///
/// The MVP intentionally stays deterministic: it can enrich existing
/// `MeetingNotes` output, or fall back to lightweight transcript heuristics
/// when notes have not been generated yet.
enum MeetingWorkflowService {
    struct Request: Sendable, Equatable {
        var title: String
        var attendees: [String]
        var transcript: String?
        var notes: MeetingNotes?
        var now: Date

        init(
            title: String,
            attendees: [String] = [],
            transcript: String? = nil,
            notes: MeetingNotes? = nil,
            now: Date = Date()
        ) {
            self.title = title
            self.attendees = attendees
            self.transcript = transcript
            self.notes = notes
            self.now = now
        }
    }

    static func generate(
        title: String,
        attendees: [String] = [],
        transcript: String? = nil,
        notes: MeetingNotes? = nil,
        now: Date = Date()
    ) -> MeetingWorkflow {
        generate(Request(title: title, attendees: attendees, transcript: transcript, notes: notes, now: now))
    }

    static func generate(_ request: Request) -> MeetingWorkflow {
        let title = normalizedTitle(request.title)
        let attendeeNames = uniqueNonEmpty(request.attendees)
        let participants = attendeeNames.enumerated().map { index, name in
            MeetingWorkflow.Participant(name: name, role: index == 0 ? .host : .participant)
        }
        let transcript = cleaned(request.transcript)
        let notes = request.notes
        let actionItems = buildActionItems(notes: notes, transcript: transcript, attendees: attendeeNames)
        let decisions = buildDecisions(notes: notes, transcript: transcript, attendees: attendeeNames)
        let risks = buildRisks(transcript: transcript, actions: actionItems, attendees: attendeeNames)
        let summary = buildSummary(title: title, notes: notes, transcript: transcript)

        let preMeeting = MeetingWorkflow.PreMeeting(
            objective: buildObjective(title: title, notes: notes, transcript: transcript),
            agenda: buildAgenda(title: title, attendees: attendeeNames, notes: notes, transcript: transcript),
            preparationItems: buildPreparationItems(attendees: attendeeNames, hasTranscript: !transcript.isEmpty),
            questionsToResolve: buildQuestionsToResolve(transcript: transcript, decisions: decisions, actions: actionItems)
        )

        let inMeeting = MeetingWorkflow.InMeeting(
            summary: summary,
            captureHints: buildCaptureHints(attendees: attendeeNames),
            decisions: decisions,
            risks: risks,
            actionItems: actionItems
        )

        let postMeeting = MeetingWorkflow.PostMeeting(
            followUpDrafts: buildFollowUpDrafts(
                title: title,
                audience: attendeeNames,
                summary: summary,
                decisions: decisions,
                risks: risks,
                actions: actionItems
            ),
            reminderSuggestions: buildReminderSuggestions(title: title, actions: actionItems, now: request.now),
            trackingSummary: buildTrackingSummary(actions: actionItems)
        )

        return MeetingWorkflow(
            title: title,
            attendees: participants,
            createdAt: request.now,
            source: source(hasTranscript: !transcript.isEmpty, notes: notes),
            preMeeting: preMeeting,
            inMeeting: inMeeting,
            postMeeting: postMeeting
        )
    }

    static func deliverableSource(from workflow: MeetingWorkflow) -> String {
        var lines: [String] = [
            "# \(workflow.title)",
            "",
            "## 会议概览",
            "- 来源：\(workflow.source.displayName)",
            "- 创建时间：\(ISO8601DateFormatter().string(from: workflow.createdAt))"
        ]
        if !workflow.attendees.isEmpty {
            lines.append("- 参会人：\(workflow.attendees.map { "\($0.name)(\($0.role.label))" }.joined(separator: "、"))")
        }

        lines.append(contentsOf: ["", "## 会前准备", workflow.preMeeting.objective])
        appendList(title: "议程", values: workflow.preMeeting.agenda.map { item in
            var text = item.title
            if let minutes = item.minutes { text += "(\(minutes) min)" }
            if let detail = item.detail, !detail.isEmpty { text += " — \(detail)" }
            return text
        }, to: &lines)
        appendList(title: "准备清单", values: workflow.preMeeting.preparationItems.map(\.title), to: &lines)
        appendList(title: "待解决问题", values: workflow.preMeeting.questionsToResolve, to: &lines)

        lines.append(contentsOf: ["", "## 会中捕获", workflow.inMeeting.summary])
        appendList(title: "决策", values: workflow.inMeeting.decisions.map { decision in
            [decision.text, decision.owner.map { "负责人：\($0)" }, decision.evidence].compactMap { $0 }.joined(separator: " · ")
        }, to: &lines)
        appendList(title: "风险", values: workflow.inMeeting.risks.map { risk in
            [risk.text, "等级：\(risk.level.label)", risk.owner.map { "负责人：\($0)" }, risk.mitigation].compactMap { $0 }.joined(separator: " · ")
        }, to: &lines)
        appendList(title: "行动项", values: workflow.inMeeting.actionItems.map { action in
            [action.title, action.owner.map { "负责人：\($0)" }, action.dueText.map { "截止：\($0)" }].compactMap { $0 }.joined(separator: " · ")
        }, to: &lines)

        lines.append(contentsOf: ["", "## 会后追踪", workflow.postMeeting.trackingSummary])
        appendList(title: "跟进消息草稿", values: workflow.postMeeting.followUpDrafts.map { "\($0.subject)\n\($0.body)" }, to: &lines)
        appendList(title: "提醒建议", values: workflow.postMeeting.reminderSuggestions.map { reminder in
            [reminder.title, reminder.suggestedAt.map { "建议时间：\(ISO8601DateFormatter().string(from: $0))" }, reminder.reason]
                .compactMap { $0 }
                .joined(separator: " · ")
        }, to: &lines)

        return lines.joined(separator: "\n")
    }
}

private extension MeetingWorkflowService {
    static func appendList(title: String, values: [String], to lines: inout [String]) {
        let cleaned = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        lines.append("")
        lines.append("### \(title)")
        lines.append(contentsOf: cleaned.map { "- \($0)" })
    }

    static func source(hasTranscript: Bool, notes: MeetingNotes?) -> MeetingWorkflow.Source {
        let hasNotes = notes.map { !$0.isEmpty } ?? false
        switch (hasTranscript, hasNotes) {
        case (true, true): return .transcriptAndNotes
        case (true, false): return .transcript
        case (false, true): return .meetingNotes
        case (false, false): return .manual
        }
    }

    static func normalizedTitle(_ raw: String) -> String {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "未命名会议" : title
    }

    static func cleaned(_ raw: String?) -> String {
        (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = name.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(name)
        }
        return result
    }

    static func buildObjective(title: String, notes: MeetingNotes?, transcript: String) -> String {
        if let summary = notes?.summary.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return "围绕「\(title)」复盘结论，并把摘要、决策、风险和行动项闭环到负责人。"
        }
        if !transcript.isEmpty {
            return "围绕「\(title)」从已有转写中梳理目标、关键结论和下一步。"
        }
        return "围绕「\(title)」对齐会议目标、议题和会后可执行产出。"
    }

    static func buildAgenda(
        title: String,
        attendees: [String],
        notes: MeetingNotes?,
        transcript: String
    ) -> [MeetingWorkflow.AgendaItem] {
        var agenda: [MeetingWorkflow.AgendaItem] = [
            .init(title: "确认会议目标", detail: "说明「\(title)」本次需要达成的结果。", minutes: 5),
            .init(title: "同步背景与当前进展", detail: transcript.isEmpty ? "补齐上下文、资料链接和约束条件。" : "基于已有转写快速确认事实是否完整。", minutes: 10),
            .init(title: "讨论关键议题与风险", detail: "逐项确认分歧、依赖、阻塞和需要拍板的地方。", minutes: 20),
            .init(title: "收敛决策与行动项", detail: "每条行动项必须有负责人、截止时间和验收口径。", minutes: 10)
        ]

        if !attendees.isEmpty {
            agenda.insert(
                .init(title: "确认参会角色", detail: "明确主持、决策人、记录人和行动项负责人。", minutes: 5),
                at: 1
            )
        }

        if let notes, !notes.decisions.isEmpty || !notes.actionItems.isEmpty {
            agenda.append(
                .init(title: "复核既有纪要", detail: "确认已有 MeetingNotes 中的决策和行动项是否准确。", minutes: 8)
            )
        }
        return agenda
    }

    static func buildPreparationItems(attendees: [String], hasTranscript: Bool) -> [MeetingWorkflow.PreparationItem] {
        var items: [MeetingWorkflow.PreparationItem] = [
            .init(title: "准备会议背景、目标和需要拍板的问题"),
            .init(title: "准备可共享的资料链接、数据截图或上下文")
        ]
        if attendees.isEmpty {
            items.append(.init(title: "补充参会人名单，并标注谁是决策人"))
        } else {
            items.append(.init(title: "提前把议程发给参会人：\(attendees.joined(separator: "、"))"))
        }
        if hasTranscript {
            items.append(.init(title: "会前快速扫一遍已有转写，标出待确认的结论"))
        }
        return items
    }

    static func buildQuestionsToResolve(
        transcript: String,
        decisions: [MeetingWorkflow.Decision],
        actions: [MeetingWorkflow.ActionItem]
    ) -> [String] {
        var questions = candidateSentences(from: transcript)
            .filter { $0.contains("?") || $0.contains("？") }
            .map { stripSpeakerPrefix($0) }
            .filter { !$0.isEmpty }

        if decisions.isEmpty {
            questions.append("本次会议最终需要拍板的决策是什么？")
        }
        if actions.contains(where: { cleaned($0.owner).isEmpty || cleaned($0.dueText).isEmpty && $0.dueDate == nil }) {
            questions.append("行动项的负责人和截止时间是否已经明确？")
        }
        if questions.isEmpty {
            questions.append("是否还有未记录的风险、依赖或开放问题？")
        }
        return Array(questions.prefix(5))
    }

    static func buildSummary(title: String, notes: MeetingNotes?, transcript: String) -> String {
        if let summary = notes?.summary.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return summary
        }
        if let first = candidateSentences(from: transcript).first {
            return "「\(title)」已有转写摘要：\(snippet(stripSpeakerPrefix(first), max: 140))"
        }
        return "「\(title)」尚未生成会议摘要。"
    }

    static func buildCaptureHints(attendees: [String]) -> [MeetingWorkflow.CaptureHint] {
        var hints: [MeetingWorkflow.CaptureHint] = [
            .init(title: "决策", detail: "听到“决定、确认、拍板、同意”时记录原话和上下文。"),
            .init(title: "风险", detail: "听到“风险、依赖、阻塞、延期、不确定”时记录影响和缓解办法。"),
            .init(title: "行动项", detail: "每个 TODO 都记录任务、负责人、截止时间和验收标准。")
        ]
        if !attendees.isEmpty {
            hints.append(.init(title: "参会人承诺", detail: "优先捕获 \(attendees.joined(separator: "、")) 的承诺和异议。"))
        }
        return hints
    }

    static func buildDecisions(
        notes: MeetingNotes?,
        transcript: String,
        attendees: [String]
    ) -> [MeetingWorkflow.Decision] {
        let notesDecisions = notes?.decisions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        if !notesDecisions.isEmpty {
            return notesDecisions.map { .init(text: $0, owner: inferOwner(in: $0, attendees: attendees), evidence: "MeetingNotes") }
        }

        let keywords = ["决定", "决议", "拍板", "确认", "同意", "定下来", "就这么定", "达成一致"]
        return uniqueCandidates(
            candidateSentences(from: transcript)
                .filter { containsAny($0, keywords) }
                .map { stripSpeakerPrefix($0) }
        )
        .prefix(6)
        .map { .init(text: $0, owner: inferOwner(in: $0, attendees: attendees), evidence: "转写") }
    }

    static func buildActionItems(
        notes: MeetingNotes?,
        transcript: String,
        attendees: [String]
    ) -> [MeetingWorkflow.ActionItem] {
        let notesActions = notes?.actionItems.map(MeetingWorkflow.ActionItem.init(from:)) ?? []
        if !notesActions.isEmpty { return notesActions }

        let keywords = ["行动项", "待办", "TODO", "todo", "负责", "跟进", "需要", "要在", "截止", "完成", "推进"]
        let candidates = uniqueCandidates(
            candidateSentences(from: transcript)
                .filter { containsAny($0, keywords) }
                .map { stripSpeakerPrefix($0) }
        )
        return candidates.prefix(8).map { sentence in
            let dueText = inferDueText(in: sentence)
            return MeetingWorkflow.ActionItem(
                title: cleanupActionTitle(sentence),
                owner: inferOwner(in: sentence, attendees: attendees),
                dueText: dueText,
                dueDate: dueText.flatMap(MeetingNotesSummarizer.parseDueDate),
                status: .open,
                source: "转写"
            )
        }
    }

    static func buildRisks(
        transcript: String,
        actions: [MeetingWorkflow.ActionItem],
        attendees: [String]
    ) -> [MeetingWorkflow.Risk] {
        let keywords = ["风险", "依赖", "阻塞", "延期", "不确定", "担心", "卡点", "资源不足", "来不及", "可能会"]
        var risks = uniqueCandidates(
            candidateSentences(from: transcript)
                .filter { containsAny($0, keywords) }
                .map { stripSpeakerPrefix($0) }
        )
        .prefix(6)
        .map { sentence in
            MeetingWorkflow.Risk(
                text: sentence,
                level: inferRiskLevel(sentence),
                mitigation: "会后指定负责人持续跟进，并在下次同步前更新状态。",
                owner: inferOwner(in: sentence, attendees: attendees)
            )
        }

        let missingOwner = actions.filter { cleaned($0.owner).isEmpty }.count
        let missingDue = actions.filter { cleaned($0.dueText).isEmpty && $0.dueDate == nil }.count
        if missingOwner > 0 || missingDue > 0 {
            var parts: [String] = []
            if missingOwner > 0 { parts.append("\(missingOwner) 个行动项缺负责人") }
            if missingDue > 0 { parts.append("\(missingDue) 个行动项缺截止时间") }
            risks.append(
                MeetingWorkflow.Risk(
                    text: parts.joined(separator: "，") + "，会后可能无法闭环。",
                    level: missingOwner > 0 ? .medium : .low,
                    mitigation: "发送跟进消息时补齐负责人和截止时间。",
                    owner: nil
                )
            )
        }
        return risks
    }

    static func buildFollowUpDrafts(
        title: String,
        audience: [String],
        summary: String,
        decisions: [MeetingWorkflow.Decision],
        risks: [MeetingWorkflow.Risk],
        actions: [MeetingWorkflow.ActionItem]
    ) -> [MeetingWorkflow.FollowUpDraft] {
        let audienceLabel = audience.isEmpty ? "参会人" : audience.joined(separator: "、")
        let body = """
        大家好，以下是「\(title)」的会后闭环草稿：

        摘要：
        \(summary)

        决策：
        \(numbered(decisions.map(\.text), empty: "暂无明确决策，请补充确认。"))

        风险：
        \(numbered(risks.map { "\($0.text)（\($0.level.label)）" }, empty: "暂无明确风险。"))

        行动项：
        \(bulleted(actions.map(actionLine), empty: "暂无明确行动项，请确认是否需要补充。"))

        请大家确认是否有遗漏或需要调整的地方；如无异议，我会按行动项继续跟进。
        """

        return [
            MeetingWorkflow.FollowUpDraft(
                channel: .message,
                audience: audienceLabel,
                subject: "【会议跟进】\(title)",
                body: body
            )
        ]
    }

    static func buildReminderSuggestions(
        title: String,
        actions: [MeetingWorkflow.ActionItem],
        now: Date
    ) -> [MeetingWorkflow.ReminderSuggestion] {
        var suggestions: [MeetingWorkflow.ReminderSuggestion] = [
            .init(
                title: "发送「\(title)」会后跟进消息",
                suggestedAt: Calendar.current.date(byAdding: .minute, value: 30, to: now),
                reason: "会后 30 分钟内发送，减少信息遗忘。"
            )
        ]

        for action in actions {
            if let dueDate = action.dueDate {
                let reminderDate = reminderDateBeforeDue(dueDate, now: now)
                suggestions.append(
                    .init(
                        title: action.reminderTitle,
                        suggestedAt: reminderDate,
                        reason: "在截止时间前提醒负责人推进。",
                        relatedActionID: action.id
                    )
                )
            } else {
                suggestions.append(
                    .init(
                        title: "补齐截止时间：\(action.title)",
                        suggestedAt: Calendar.current.date(byAdding: .day, value: 1, to: now),
                        reason: "该行动项还没有可解析的截止时间。",
                        relatedActionID: action.id
                    )
                )
            }
        }

        if actions.isEmpty {
            suggestions.append(
                .init(
                    title: "确认「\(title)」是否需要补充行动项",
                    suggestedAt: Calendar.current.date(byAdding: .day, value: 1, to: now),
                    reason: "当前闭环里没有行动项，建议会后再次确认。"
                )
            )
        }
        return suggestions
    }

    static func buildTrackingSummary(actions: [MeetingWorkflow.ActionItem]) -> String {
        guard !actions.isEmpty else { return "暂无行动项，建议会后确认是否需要补充。" }
        let open = actions.filter { $0.status != .done }.count
        let missingOwner = actions.filter { cleaned($0.owner).isEmpty }.count
        let missingDue = actions.filter { cleaned($0.dueText).isEmpty && $0.dueDate == nil }.count
        return "\(open) 个行动项待跟进，\(missingOwner) 个缺负责人，\(missingDue) 个缺截止时间。"
    }

    static func reminderDateBeforeDue(_ dueDate: Date, now: Date) -> Date {
        guard dueDate > now else { return now }
        let oneDayBefore = Calendar.current.date(byAdding: .day, value: -1, to: dueDate) ?? dueDate
        return oneDayBefore > now ? oneDayBefore : dueDate
    }

    static func actionLine(_ action: MeetingWorkflow.ActionItem) -> String {
        var parts = [action.title]
        if let owner = action.owner, !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("负责人：\(owner)")
        }
        if let due = action.dueText, !due.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("截止：\(due)")
        }
        return parts.joined(separator: "｜")
    }

    static func numbered(_ values: [String], empty: String) -> String {
        let cleanedValues = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleanedValues.isEmpty else { return empty }
        return cleanedValues.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    static func bulleted(_ values: [String], empty: String) -> String {
        let cleanedValues = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleanedValues.isEmpty else { return empty }
        return cleanedValues.map { "- [ ] \($0)" }.joined(separator: "\n")
    }

    static func candidateSentences(from transcript: String) -> [String] {
        transcript
            .components(separatedBy: CharacterSet(charactersIn: "\n。！？!?；;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func stripSpeakerPrefix(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) {
            let prefix = String(text[..<colon])
            if prefix.count <= 8 || prefix == "我" || prefix == "对方" {
                text = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    static func cleanupActionTitle(_ sentence: String) -> String {
        var text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["行动项", "待办", "TODO", "todo"]
        for prefix in prefixes where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: " ：:-—"))
        }
        return text
    }

    static func inferOwner(in text: String, attendees: [String]) -> String? {
        for attendee in attendees where text.contains(attendee) {
            return attendee
        }
        if text.contains("我来") || text.contains("我负责") || text.contains("我跟进") {
            return "我"
        }
        if text.contains("对方负责") || text.contains("对方跟进") {
            return "对方"
        }
        if let owner = match(text, pattern: #"由\s*([\u{4e00}-\u{9fa5}A-Za-z0-9_]{1,12})\s*(?:来|负责|跟进)"#, group: 1) {
            return owner
        }
        if let owner = match(text, pattern: #"([\u{4e00}-\u{9fa5}A-Za-z0-9_]{1,12})\s*(?:来|负责|跟进)"#, group: 1) {
            return owner
        }
        return nil
    }

    static func inferDueText(in text: String) -> String? {
        let patterns = [
            #"\d{4}[-/]\d{1,2}[-/]\d{1,2}(?:\s+\d{1,2}:\d{2}(?::\d{2})?)?"#,
            #"\d{4}年\d{1,2}月\d{1,2}日(?:\s+\d{1,2}:\d{2})?"#,
            #"\d{1,2}月\d{1,2}日"#,
            #"(?:本周|这周|下周|周)[一二三四五六日天]"#,
            #"(?:今天|明天|后天|月底|月末|本月底|下月底|下月初)"#
        ]
        for pattern in patterns {
            if let value = match(text, pattern: pattern, group: 0) { return value }
        }
        return nil
    }

    static func inferRiskLevel(_ text: String) -> MeetingWorkflow.RiskLevel {
        if containsAny(text, ["阻塞", "严重", "高风险", "无法", "延期", "来不及"]) {
            return .high
        }
        if containsAny(text, ["依赖", "不确定", "担心", "卡点", "资源不足"]) {
            return .medium
        }
        return .low
    }

    static func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.localizedCaseInsensitiveContains($0) }
    }

    static func uniqueCandidates(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    static func match(_ text: String, pattern: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let result = regex.firstMatch(in: text, range: nsRange),
              result.numberOfRanges > group,
              let range = Range(result.range(at: group), in: text) else {
            return nil
        }
        let value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func snippet(_ text: String, max: Int) -> String {
        text.count <= max ? text : String(text.prefix(max)) + "…"
    }
}
