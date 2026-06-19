import SwiftUI

/// Standalone renderer for Meeting Close-loop 2.0.
///
/// It does not depend on navigation, settings, or `AppViewModel`, so the main
/// app can embed it later from any sheet, inspector, or detail route.
struct MeetingWorkflowView: View {
    let workflow: MeetingWorkflow
    let embeddedInSettings: Bool
    @State private var showingDeliverable = false

    private let preTint = Color(red: 0.18, green: 0.48, blue: 0.74)
    private let inTint = Color(red: 0.85, green: 0.42, blue: 0.18)
    private let postTint = Color(red: 0.24, green: 0.58, blue: 0.35)

    init(workflow: MeetingWorkflow, embeddedInSettings: Bool = false) {
        self.workflow = workflow
        self.embeddedInSettings = embeddedInSettings
    }

    init(
        title: String,
        attendees: [String] = [],
        transcript: String? = nil,
        notes: MeetingNotes? = nil,
        embeddedInSettings: Bool = false
    ) {
        self.workflow = MeetingWorkflowService.generate(
            title: title,
            attendees: attendees,
            transcript: transcript,
            notes: notes
        )
        self.embeddedInSettings = embeddedInSettings
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroCard
                phaseStrip
                preMeetingSection
                inMeetingSection
                postMeetingSection
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .sheet(isPresented: $showingDeliverable) {
            DeliverableStudioView(request: DeliverableRequest(
                title: "\(workflow.title) 会议交付物",
                sourceKind: .meeting,
                targetKind: .webpage,
                sourceText: MeetingWorkflowService.deliverableSource(from: workflow),
                audience: workflow.attendees.map(\.name).joined(separator: "、"),
                goal: "把会前准备、会中捕获和会后追踪整理成可分享页面"
            ), showsCloseButton: true)
        }
        #if os(macOS)
        .frame(minWidth: 580, minHeight: embeddedInSettings ? 0 : 680)
        #endif
    }
}

private extension MeetingWorkflowView {
    var heroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(inTint)

                VStack(alignment: .leading, spacing: 5) {
                    Text(workflow.title)
                        .font(.title3.weight(.bold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("会议闭环 2.0 · \(sourceLabel)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Button {
                    showingDeliverable = true
                } label: {
                    Label("交付/发布", systemImage: "shippingbox.and.arrow.backward")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(
                            LinearGradient(
                                colors: [postTint.opacity(0.18), postTint.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: Capsule(style: .continuous)
                        )
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(postTint.opacity(0.24), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .foregroundStyle(postTint)
            }

            if workflow.attendees.isEmpty {
                Label("尚未添加参会人", systemImage: "person.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                tagCloud(workflow.attendees.map { "\($0.name) · \($0.role.label)" }, tint: inTint)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [inTint.opacity(0.14), preTint.opacity(0.10), postTint.opacity(0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    var phaseStrip: some View {
        HStack(spacing: 8) {
            phasePill(index: 1, title: "会前", subtitle: "\(workflow.preMeeting.agenda.count) 个议程", color: preTint)
            connector
            phasePill(index: 2, title: "会中", subtitle: "\(workflow.inMeeting.decisions.count) 个决策", color: inTint)
            connector
            phasePill(index: 3, title: "会后", subtitle: "\(workflow.postMeeting.reminderSuggestions.count) 个提醒", color: postTint)
        }
        .padding(.horizontal, 2)
    }

    var connector: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.22))
            .frame(width: 18, height: 2)
    }

    func phasePill(index: Int, title: String, subtitle: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Text("\(index)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(color, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.bold))
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    var preMeetingSection: some View {
        phaseSection(title: "会前准备", icon: "calendar.badge.checkmark", tint: preTint) {
            if !workflow.preMeeting.objective.isEmpty {
                labeledText("目标", workflow.preMeeting.objective)
            }

            if !workflow.preMeeting.agenda.isEmpty {
                subsectionTitle("议程")
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(workflow.preMeeting.agenda) { item in
                        agendaRow(item)
                    }
                }
            }

            if !workflow.preMeeting.preparationItems.isEmpty {
                subsectionTitle("准备清单")
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(workflow.preMeeting.preparationItems) { item in
                        checklistRow(
                            title: item.title,
                            meta: item.owner,
                            required: item.isRequired,
                            tint: preTint
                        )
                    }
                }
            }

            if !workflow.preMeeting.questionsToResolve.isEmpty {
                subsectionTitle("待解决问题")
                bulletList(workflow.preMeeting.questionsToResolve, tint: preTint)
            }
        }
    }

    var inMeetingSection: some View {
        phaseSection(title: "会中捕获", icon: "waveform.badge.mic", tint: inTint) {
            labeledText("摘要", workflow.inMeeting.summary)

            if !workflow.inMeeting.captureHints.isEmpty {
                subsectionTitle("捕获提示")
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(workflow.inMeeting.captureHints) { hint in
                        compactCard(icon: "scope", title: hint.title, detail: hint.detail, tint: inTint)
                    }
                }
            }

            if !workflow.inMeeting.decisions.isEmpty {
                subsectionTitle("决策")
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(workflow.inMeeting.decisions) { decision in
                        compactCard(
                            icon: "checkmark.seal",
                            title: decision.text,
                            detail: joinedMeta(["负责人：\(decision.owner ?? "")", decision.evidence]),
                            tint: inTint
                        )
                    }
                }
            }

            if !workflow.inMeeting.risks.isEmpty {
                subsectionTitle("风险")
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(workflow.inMeeting.risks) { risk in
                        riskRow(risk)
                    }
                }
            }

            if !workflow.inMeeting.actionItems.isEmpty {
                subsectionTitle("行动项")
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(workflow.inMeeting.actionItems) { action in
                        actionRow(action, tint: inTint)
                    }
                }
            }
        }
    }

    var postMeetingSection: some View {
        phaseSection(title: "会后追踪", icon: "checklist.checked", tint: postTint) {
            labeledText("追踪概览", workflow.postMeeting.trackingSummary)

            if !workflow.postMeeting.followUpDrafts.isEmpty {
                subsectionTitle("跟进消息草稿")
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(workflow.postMeeting.followUpDrafts) { draft in
                        draftCard(draft)
                    }
                }
            }

            if !workflow.postMeeting.reminderSuggestions.isEmpty {
                subsectionTitle("提醒建议")
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(workflow.postMeeting.reminderSuggestions) { reminder in
                        reminderRow(reminder)
                    }
                }
            }
        }
    }

    func phaseSection<Content: View>(
        title: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline.weight(.bold))
                .foregroundStyle(tint)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 1)
        }
    }

    func subsectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    func labeledText(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text(text.isEmpty ? "暂无内容" : text)
                .font(.callout)
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func agendaRow(_ item: MeetingWorkflow.AgendaItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(preTint)
                .font(.callout)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title).font(.callout.weight(.medium))
                    Spacer(minLength: 8)
                    if let minutes = item.minutes {
                        Text("\(minutes) min")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                if let owner = item.owner, !owner.isEmpty {
                    Label(owner, systemImage: "person")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(preTint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    func checklistRow(title: String, meta: String?, required: Bool, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: required ? "checkmark.circle" : "circle")
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout)
                if let meta, !meta.isEmpty {
                    Text(meta).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func compactCard(icon: String, title: String, detail: String?, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.callout)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.medium))
                if let detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    func riskRow(_ risk: MeetingWorkflow.Risk) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(color(for: risk.level))
                Text(risk.text)
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(risk.level.label)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .foregroundStyle(color(for: risk.level))
                    .background(color(for: risk.level).opacity(0.12), in: Capsule())
            }
            if let mitigation = risk.mitigation, !mitigation.isEmpty {
                Text(mitigation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)
            }
        }
        .padding(10)
        .background(color(for: risk.level).opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    func actionRow(_ action: MeetingWorkflow.ActionItem, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: action.status == .done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(action.status == .done ? postTint : tint)
            VStack(alignment: .leading, spacing: 5) {
                Text(action.title)
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                tagCloud(actionMeta(action), tint: tint)
            }
        }
        .padding(10)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    func draftCard(_ draft: MeetingWorkflow.FollowUpDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(draft.channel.label, systemImage: draft.channel == .email ? "envelope" : "message")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(postTint)
                Spacer()
                Text(draft.audience)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(draft.subject)
                .font(.callout.weight(.semibold))
            Text(draft.body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(postTint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    func reminderRow(_ reminder: MeetingWorkflow.ReminderSuggestion) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bell.badge")
                .foregroundStyle(postTint)
            VStack(alignment: .leading, spacing: 4) {
                Text(reminder.title)
                    .font(.callout.weight(.medium))
                Text(reminder.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let date = reminder.suggestedAt {
                    Label(dateLabel(date), systemImage: "clock")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func bulletList(_ values: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(values, id: \.self) { value in
                HStack(alignment: .top, spacing: 8) {
                    Text("•").foregroundStyle(tint)
                    Text(value).font(.callout)
                }
            }
        }
    }

    func tagCloud(_ values: [String], tint: Color) -> some View {
        let cleaned = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return FlowLikeTags(values: cleaned, tint: tint)
    }

    func actionMeta(_ action: MeetingWorkflow.ActionItem) -> [String] {
        var values = [action.status.label]
        if let owner = action.owner, !owner.isEmpty { values.append(owner) }
        if let dueText = action.dueText, !dueText.isEmpty { values.append(dueText) }
        if action.dueText == nil, action.dueDate != nil { values.append("有截止日期") }
        return values
    }

    func joinedMeta(_ values: [String?]) -> String? {
        let joined = values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasSuffix("：") }
            .joined(separator: " · ")
        return joined.isEmpty ? nil : joined
    }

    func color(for level: MeetingWorkflow.RiskLevel) -> Color {
        switch level {
        case .low: return postTint
        case .medium: return inTint
        case .high: return Color.red
        }
    }

    var sourceLabel: String {
        switch workflow.source {
        case .manual: return "手动输入"
        case .transcript: return "来自转写"
        case .meetingNotes: return "来自 MeetingNotes"
        case .transcriptAndNotes: return "转写 + MeetingNotes"
        }
    }

    func dateLabel(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().hour().minute())
    }
}

private struct FlowLikeTags: View {
    let values: [String]
    let tint: Color

    var body: some View {
        if values.isEmpty {
            EmptyView()
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(values, id: \.self) { value in
                    Text(value)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(tint)
                        .background(tint.opacity(0.10), in: Capsule())
                }
            }
        }
    }
}
