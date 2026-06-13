import SwiftUI

/// 盲测运行器:把同一个问题发给两个**匿名**模型,并发流式收答。模型身份在用户裁决前对 UI 隐藏。
/// 自包含、view 持有(@State),不与全局发送编排耦合;复用 `ProviderRegistry` + `ChatOptions` 流式范式。
@Observable
@MainActor
final class BlindTasteRunner {
    enum Phase: Equatable { case idle, running, done }

    /// 一侧(A / B)的运行态。
    @Observable
    @MainActor
    final class Side: Identifiable {
        let id = UUID()
        /// 被测 provider 配置(身份,裁决前不展示)。
        let config: ProviderConfig
        var text: String = ""
        var error: String?
        var finished = false

        init(config: ProviderConfig) { self.config = config }

        /// 模型键(`providerKind::model`),记入偏好画像用。
        var modelKey: String {
            PreferenceProfileStore.key(providerKind: config.kind, model: config.model)
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var question: String = ""
    private(set) var category: TaskCategory = .qa
    private(set) var sideA: Side?
    private(set) var sideB: Side?
    /// 本轮裁决是否已记录(防重复计票)。
    private(set) var voted = false

    private var task: Task<Void, Never>?

    /// 两侧都已结束(成功或失败)。
    var bothFinished: Bool {
        (sideA?.finished ?? false) && (sideB?.finished ?? false)
    }

    /// 开一轮盲测:从候选池随机取两家不同的模型,并发流式收答。
    /// 候选不足两家时设 idle 并返回 false(调用方提示)。
    @discardableResult
    func start(question: String, pool: [ProviderConfig]) -> Bool {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard pool.count >= 2 else { return false }

        cancel()
        // 随机取两家不同的(provider, model)。同一 provider 配置只参与一次,保证 A≠B。
        let shuffled = pool.shuffled()
        let a = shuffled[0]
        let b = shuffled[1]

        self.question = trimmed
        self.category = TaskCategory.classify(trimmed)
        self.sideA = Side(config: a)
        self.sideB = Side(config: b)
        self.voted = false
        self.phase = .running

        task = Task { @MainActor [weak self] in
            guard let self, let sa = self.sideA, let sb = self.sideB else { return }
            // 两侧并发,各自把流式文本写回自己的 Side。
            async let ra: Void = self.stream(into: sa)
            async let rb: Void = self.stream(into: sb)
            _ = await (ra, rb)
            if !Task.isCancelled { self.phase = .done }
        }
        return true
    }

    func cancel() {
        task?.cancel()
        task = nil
        if phase == .running { phase = .idle }
    }

    private func stream(into side: Side) async {
        defer { side.finished = true }
        do {
            let apiKey = side.config.kind.needsAPIKey ? (try KeychainStore.load(id: side.config.id)) : ""
            let client = ProviderRegistry.client(for: side.config.kind)
            let options = ChatOptions(systemPrompt: nil,
                                      temperature: side.config.temperature,
                                      maxTokens: side.config.maxTokens)
            for try await chunk in client.stream(prompt: question, options: options, config: side.config, apiKey: apiKey) {
                if Task.isCancelled { return }
                switch chunk {
                case .text(let t):
                    side.text += t
                case .usage(let i, let o, let c):
                    UsageStore.shared.record(providerKind: side.config.kind, model: side.config.model,
                                             inputTokens: i, outputTokens: o, cachedTokens: c)
                default:
                    break
                }
            }
        } catch is CancellationError {
            // 取消不算错误。
        } catch {
            if side.error == nil { side.error = error.localizedDescription }
        }
    }

    /// 裁决:winner = .a / .b;记入偏好画像并揭示身份。重复调用忽略。
    enum Choice { case a, b, tie }
    func vote(_ choice: Choice) {
        guard !voted, let sa = sideA, let sb = sideB else { return }
        voted = true
        switch choice {
        case .a:   PreferenceProfileStore.shared.recordVote(winnerKey: sa.modelKey, loserKey: sb.modelKey, category: category)
        case .b:   PreferenceProfileStore.shared.recordVote(winnerKey: sb.modelKey, loserKey: sa.modelKey, category: category)
        case .tie: PreferenceProfileStore.shared.recordTie(sa.modelKey, sb.modelKey, category: category)
        }
    }
}

/// 个人口味盲测:同一问题两个匿名模型出答案,用户亲自选更好的那个 → 累积成个人偏好画像。
/// Direct「用我的偏好」路由(`PreferenceRouter`)就吃这份画像。自包含:输入 + 双栏匿名答案 +
/// 裁决 + 身份揭示 + 偏好榜全在本文件。可作设置页(routing tab)或 sheet 入口。
struct BlindTasteTestView: View {
    @Bindable var viewModel: AppViewModel

    @State private var runner = BlindTasteRunner()
    @State private var input: String = ""
    @State private var profile = PreferenceProfileStore.shared

    private let tint = Color(red: 0.46, green: 0.40, blue: 0.90)
    private let aColor = Color(red: 0.24, green: 0.56, blue: 0.90)
    private let bColor = Color(red: 0.86, green: 0.42, blue: 0.30)

    /// 可参与盲测的模型:已启用、非 CLI(盲测要并发流式,CLI 子进程不适合)。
    private var pool: [ProviderConfig] {
        viewModel.providers.filter { $0.enabled && !$0.kind.isCLI }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroCard
                inputCard
                if runner.sideA != nil && runner.sideB != nil {
                    arena
                }
                profileCard
            }
            .padding(contentPadding)
            .frame(maxWidth: 900, alignment: .topLeading)
        }
        #if os(iOS)
        .background(Color.platformWindowBackground.ignoresSafeArea())
        .scrollIndicators(.hidden)
        #endif
    }

    private var contentPadding: CGFloat {
        #if os(iOS)
        return 14
        #else
        return 24
        #endif
    }

    // MARK: - Hero

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.65)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "eye.slash.fill").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("个人口味盲测").font(.system(.title2, design: .rounded).weight(.bold))
                    Text("同一问题,两个**匿名**模型作答,你来选更合口味的那个。结果按任务类别攒成你的个人偏好画像。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Label("开启 设置 ▸ 模型路由 里的「用我的偏好」后,Direct 模式会按这份画像替你选模型。",
                  systemImage: "info.circle.fill")
                .font(.caption).foregroundStyle(tint)
                .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBg(tint))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(tint.opacity(0.22), lineWidth: 1) }
    }

    // MARK: - 输入

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("出一道题").font(.headline)
            TextEditor(text: $input)
                .font(.body)
                .frame(minHeight: 80, maxHeight: 160)
                .padding(8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
                }
            HStack(spacing: 10) {
                if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label("将归入「\(TaskCategory.classify(input).label)」", systemImage: "tag.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(tint)
                }
                Spacer(minLength: 0)
                Button {
                    runner.cancel()
                    if !runner.start(question: input, pool: pool) {
                        // 候选不足时不动 UI;按钮 disabled 已基本拦住。
                    }
                } label: {
                    Label(runner.phase == .running ? "出题中…" : "开始盲测", systemImage: "play.fill")
                        .font(.callout.weight(.bold))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(canStart ? tint : Color.secondary.opacity(0.4), in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!canStart)
            }
            if pool.count < 2 {
                Label("盲测需要至少 2 个已启用、非 CLI 的模型。到 设置 ▸ 厂商 里多启用一个。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBg(tint))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(tint.opacity(0.16), lineWidth: 1) }
    }

    private var canStart: Bool {
        pool.count >= 2 && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && runner.phase != .running
    }

    // MARK: - 对战区

    @ViewBuilder
    private var arena: some View {
        if let sa = runner.sideA, let sb = runner.sideB {
            VStack(alignment: .leading, spacing: 12) {
                // 双栏匿名答案(宽屏并排,窄屏堆叠)。
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        answerColumn(side: sa, label: "模型 A", color: aColor)
                        answerColumn(side: sb, label: "模型 B", color: bColor)
                    }
                    VStack(spacing: 12) {
                        answerColumn(side: sa, label: "模型 A", color: aColor)
                        answerColumn(side: sb, label: "模型 B", color: bColor)
                    }
                }
                verdictBar(sa: sa, sb: sb)
            }
        }
    }

    private func answerColumn(side: BlindTasteRunner.Side, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(label).font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(color, in: Capsule())
                if !side.finished {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                // 已裁决后揭示身份。
                if runner.voted {
                    Text(side.config.displayName + " · " + side.config.model)
                        .font(.caption2.weight(.bold)).foregroundStyle(color)
                        .lineLimit(1)
                }
            }
            if let err = side.error, side.text.isEmpty {
                Text(err).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if side.text.isEmpty && !side.finished {
                Text("正在生成…").font(.callout).foregroundStyle(.secondary)
            } else {
                MarkdownText(text: side.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(color.opacity(0.20), lineWidth: 1) }
    }

    @ViewBuilder
    private func verdictBar(sa: BlindTasteRunner.Side, sb: BlindTasteRunner.Side) -> some View {
        if runner.voted {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text("已记录这次裁决到「\(runner.category.label)」偏好。").font(.callout.weight(.semibold))
                Spacer()
                Button {
                    runner.cancel()
                    runner.start(question: input, pool: pool)
                } label: {
                    Label("再来一题", systemImage: "arrow.clockwise").font(.callout.weight(.bold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(tint.opacity(0.14), in: Capsule()).foregroundStyle(tint)
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            VStack(spacing: 10) {
                Text(runner.bothFinished ? "哪个更合你的口味?" : "等两边都答完再选 ——")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    voteButton("A 更好", color: aColor) { runner.vote(.a) }
                    voteButton("难分伯仲", color: .secondary) { runner.vote(.tie) }
                    voteButton("B 更好", color: bColor) { runner.vote(.b) }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tint.opacity(0.16), lineWidth: 1) }
        }
    }

    private func voteButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.callout.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(color == .secondary ? Color.primary : color)
        }
        .buttonStyle(.plain)
        .disabled(!runner.bothFinished)
        .opacity(runner.bothFinished ? 1 : 0.5)
    }

    // MARK: - 偏好画像榜

    @ViewBuilder
    private var profileCard: some View {
        let categories = profile.nonEmptyCategories
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("我的偏好画像", systemImage: "person.crop.circle.badge.checkmark").font(.headline)
                Spacer()
                Text("\(profile.totalVotes) 次裁决").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                if !categories.isEmpty {
                    Button(role: .destructive) { profile.reset() } label: {
                        Label("清空", systemImage: "trash").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain).foregroundStyle(.red)
                }
            }
            if categories.isEmpty {
                Text("还没有偏好数据。在上面做几轮盲测,这里就会按任务类别列出你最常选的模型。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(categories, id: \.self) { cat in
                    categorySection(cat)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBg(tint))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(tint.opacity(0.16), lineWidth: 1) }
    }

    private func categorySection(_ cat: TaskCategory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(cat.label).font(.subheadline.weight(.bold)).foregroundStyle(tint)
            ForEach(profile.standings(category: cat)) { row in
                HStack(spacing: 10) {
                    Text(row.model).font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(Int((row.record.preferenceRate * 100).rounded()))%")
                        .font(.callout.weight(.bold)).monospacedDigit().foregroundStyle(tint)
                    Text("\(row.record.wins)胜\(row.record.losses)负" + (row.record.draws > 0 ? "\(row.record.draws)平" : ""))
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func cardBg(_ tint: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.08), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }
}
