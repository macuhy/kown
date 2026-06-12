import SwiftUI
import MarkdownUI
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

/// 用于导出成图片的回答卡片(ImageRenderer 渲染目标)。固定宽度、浅色底。
/// 用 MarkdownUI 渲染完整 markdown(标题/代码块/表格/列表),代码块自动换行不撑宽。
struct AnswerCardImage: View {
    let providerName: String
    let model: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .foregroundStyle(Color.accentColor)
                Text(providerName).font(.headline)
                Text(model).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1)
            Markdown(MD.stylizeMath(text))
                .markdownTheme(MD.exportTheme)
                .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1)
            Text("via Kown").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 600, alignment: .leading)
        .background(Color(white: 0.99))
    }
}

// MARK: - 整轮 / 整会话 分享图(并排布局)

/// 单 panel 宽度;多模型横向并排时每列都用它。
private let kSharePanelWidth: CGFloat = 360
/// Direct(单模型)用更宽的单列,读起来更舒服。
private let kShareDirectWidth: CGFloat = 560
/// 列间距。
private let kShareGap: CGFloat = 14
/// 导出图浅色底。
private let kShareCanvas = Color(white: 0.97)
private let kShareCard = Color(white: 0.995)

/// 截断超长文本,避免单张图尺寸失控。
private func shareCap(_ s: String) -> String {
    s.count > 4000 ? String(s.prefix(4000)) + "\n\n…(已截断)" : s
}

/// provider 配色(与 `HistoricalResponseCard.accentColor` 一致)。
private func shareAccent(_ kind: ProviderKind) -> Color {
    switch kind {
    case .openAICompatible: return Color(red: 0.06, green: 0.64, blue: 0.50)
    case .anthropic:        return Color(red: 0.83, green: 0.38, blue: 0.18)
    case .gemini:           return Color(red: 0.26, green: 0.52, blue: 0.96)
    case .cliCommand:       return Color(red: 0.55, green: 0.45, blue: 0.78)
    case .appleFM:          return Color(red: 0.78, green: 0.40, blue: 0.86)
    }
}

private func shareSymbol(_ kind: ProviderKind) -> String {
    switch kind {
    case .openAICompatible: return "sparkles"
    case .anthropic:        return "text.book.closed"
    case .gemini:           return "diamond.fill"
    case .cliCommand:       return "terminal"
    case .appleFM:          return "apple.logo"
    }
}

/// 一个 provider 的回答卡片(导出用):顶部 accent 条 + provider/model 头 + markdown 正文。
private struct ShareAnswerPanel: View {
    let config: ProviderConfig
    let text: String
    let error: String?
    var width: CGFloat = kSharePanelWidth
    /// true=超长截断(图片用,防超大图);false=全文(PDF 用)。
    var capText: Bool = true

    private var accent: Color { shareAccent(config.kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(accent).frame(height: 4)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: shareSymbol(config.kind))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(config.displayName)
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                            .lineLimit(1)
                        Text(config.model)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                Rectangle().fill(accent.opacity(0.16)).frame(height: 1)
                content
            }
            .padding(14)
        }
        .frame(width: width, alignment: .leading)
        .background(kShareCard)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(accent.opacity(0.22), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error, !error.isEmpty {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if text.isEmpty {
            Text("(空响应)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Markdown(MD.stylizeMath(capText ? shareCap(text) : text))
                .markdownTheme(MD.exportTheme)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 综合 / 裁判 / 总结 / 主持卡片(导出用),复用 `ChairSummaryCard.Role` 的文案配色。
private struct ShareChairBlock: View {
    let config: ProviderConfig
    let text: String
    let role: ChairSummaryCard.Role
    var width: CGFloat
    var capText: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: role.icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(role.tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text("\(role.prefix) · \(config.displayName)")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .lineLimit(1)
                Text(role.badge)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(role.tint)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(role.tint.opacity(0.14), in: Capsule())
                Spacer(minLength: 0)
            }
            Rectangle().fill(role.tint.opacity(0.18)).frame(height: 1)
            Markdown(MD.stylizeMath(capText ? shareCap(text) : text))
                .markdownTheme(MD.exportTheme)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(width: width, alignment: .leading)
        .background(kShareCard)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(role.tint.opacity(0.30), lineWidth: 1)
        }
    }
}

/// 一整轮的导出卡片:prompt 头 + 并排回答 + 综合/裁判/总结/主持。
struct ShareTurnCard: View {
    let turn: Turn
    let mode: ConversationMode
    /// 预加载好的用户附图(ImageRenderer 同步渲染,异步 .task 不会触发,必须预加载)。
    var preloadedImages: [PlatformImage] = []
    /// true=超长截断(图片);false=全文(PDF)。
    var capText: Bool = true

    /// 横向并排的 panel(compare 仅取前 2)。
    private var panels: [ProviderConfig] {
        mode == .compare ? Array(turn.orderedPanelConfigs.prefix(2)) : turn.orderedPanelConfigs
    }

    /// 单列宽度(Direct 用宽列,其余用标准列)。
    private var panelWidth: CGFloat { mode == .direct ? kShareDirectWidth : kSharePanelWidth }

    /// 并排区总宽(也是 prompt 头 / 综合块的对齐宽度)。
    private var rowWidth: CGFloat {
        let n = max(panels.count, 1)
        return CGFloat(n) * panelWidth + CGFloat(n - 1) * kShareGap
    }

    private func roundConfigs(_ round: DebateRound) -> [ProviderConfig] {
        let order = round.panelOrder.isEmpty ? turn.panelOrder : round.panelOrder
        return order.compactMap { turn.providerSnapshot[$0] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            promptHeader
            answersBody
            if let chair = turn.chairConfig, let t = turn.chairSummary, !t.isEmpty {
                ShareChairBlock(config: chair, text: t, role: chairRole, width: rowWidth, capText: capText)
            }
            if let summary = turn.summaryConfig, let t = turn.summaryText, !t.isEmpty {
                ShareChairBlock(config: summary, text: t, role: .summary, width: rowWidth, capText: capText)
            }
        }
        .frame(width: rowWidth, alignment: .leading)
    }

    /// council=综合 / compare=裁判 / debate=主持。
    private var chairRole: ChairSummaryCard.Role {
        switch mode {
        case .compare: return .judge
        case .debate:  return .moderator
        default:       return .chair
        }
    }

    private var promptHeader: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("You")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                Text(turn.timestamp, style: .date)
                    .font(.caption2).foregroundStyle(.secondary)
                Text(turn.timestamp, style: .time)
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if !turn.prompt.isEmpty {
                Text(turn.prompt)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !preloadedImages.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(preloadedImages.enumerated()), id: \.offset) { _, img in
                        platformImage(img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 130)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .frame(width: rowWidth, alignment: .leading)
        .background(Color.accentColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.16), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var answersBody: some View {
        if mode == .debate, let rounds = turn.debateRounds, !rounds.isEmpty {
            ForEach(rounds.sorted { $0.index < $1.index }) { round in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("ROUND \(round.index)")
                            .font(.system(.caption2, design: .monospaced).weight(.bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                        if !round.title.isEmpty {
                            Text(round.title)
                                .font(.system(.subheadline, design: .rounded).weight(.bold))
                        }
                        Spacer(minLength: 0)
                    }
                    panelRow(roundConfigs(round)) { cfg in
                        (round.responses[cfg.id.uuidString] ?? "", round.errors[cfg.id.uuidString])
                    }
                }
            }
        } else {
            panelRow(panels) { cfg in
                (turn.responses[cfg.id.uuidString] ?? "", turn.errors[cfg.id.uuidString])
            }
        }
    }

    /// 把一组 config 横向并排成一行回答 panel。
    private func panelRow(_ configs: [ProviderConfig],
                          _ pick: @escaping (ProviderConfig) -> (String, String?)) -> some View {
        HStack(alignment: .top, spacing: kShareGap) {
            ForEach(configs) { cfg in
                let (text, err) = pick(cfg)
                ShareAnswerPanel(config: cfg, text: text, error: err, width: panelWidth, capText: capText)
            }
        }
    }
}

/// 一整个会话的导出卡片:标题 + 模式 + 逐轮纵向堆叠(每轮内并排)。
struct ShareSessionCard: View {
    let conversation: Conversation
    /// turn.id → 预加载的附图。
    var preloaded: [UUID: [PlatformImage]] = [:]
    /// true=超长截断(图片);false=全文(PDF)。
    var capText: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                Image(systemName: conversation.mode.symbol)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.title)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .lineLimit(2)
                    Text("\(conversation.mode.displayName) · \(conversation.turns.count) 轮")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            ForEach(conversation.turns) { turn in
                ShareTurnCard(turn: turn, mode: conversation.mode,
                              preloadedImages: preloaded[turn.id] ?? [], capText: capText)
            }
            Text("via Kown")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(24)
        .background(kShareCanvas)
    }
}

/// 在 SwiftUI 里显示平台图片。
private func platformImage(_ img: PlatformImage) -> Image {
    #if os(macOS)
    Image(nsImage: img)
    #else
    Image(uiImage: img)
    #endif
}

// MARK: - 导出器

/// 把回答 / 整轮 / 整会话渲染成图片卡片并**直接复制到剪贴板**(不弹保存 / 分享)。
enum AnswerImageExporter {
    /// 渲染并复制到剪贴板。成功返回 true(供 UI 显示「已复制」)。
    @discardableResult @MainActor
    static func copyToClipboard(providerName: String, model: String, text: String) -> Bool {
        // 超长截断,避免生成超大图片
        let capped = text.count > 4000 ? String(text.prefix(4000)) + "\n\n…(已截断)" : text
        let renderer = ImageRenderer(content: AnswerCardImage(providerName: providerName, model: model, text: capped))
        return copy(renderer)
    }

    /// 单轮 → 图片(并排各模型回答),复制到剪贴板。
    @discardableResult @MainActor
    static func copyTurnToClipboard(turn: Turn, mode: ConversationMode) -> Bool {
        let imgs = preloadImages(turn)
        let renderer = ImageRenderer(content:
            ShareTurnCard(turn: turn, mode: mode, preloadedImages: imgs)
                .padding(20)
                .background(kShareCanvas)
        )
        return copy(renderer)
    }

    /// 整会话 → 一张长图,复制到剪贴板。
    @discardableResult @MainActor
    static func copySessionToClipboard(conversation: Conversation) -> Bool {
        var map: [UUID: [PlatformImage]] = [:]
        for turn in conversation.turns {
            let imgs = preloadImages(turn)
            if !imgs.isEmpty { map[turn.id] = imgs }
        }
        let renderer = ImageRenderer(content: ShareSessionCard(conversation: conversation, preloaded: map))
        return copy(renderer)
    }

    /// 整会话 → 多页 PDF(矢量文字、全文不截断)。失败返回 nil。
    /// **按块分页**:会话头 + 每轮卡片 + 页脚各为一块,分页只发生在块之间(不切到行),
    /// 只有单块本身比整页还高时才按页切。块用 ImageRenderer 矢量画进 PDF 上下文。
    /// ImageRenderer 必须在主线程跑(SwiftUI 渲染不可挪后台),所以改成 `async` 并在**块之间 `Task.yield()`**:
    /// 让主线程在两块渲染之间喘口气、能响应点击/刷新进度,把原来一口气 3–5s 的卡死摊成可响应的逐块渲染。
    @MainActor
    static func sessionPDF(conversation: Conversation) async -> Data? {
        var map: [UUID: [PlatformImage]] = [:]
        for turn in conversation.turns {
            let imgs = preloadImages(turn)
            if !imgs.isEmpty { map[turn.id] = imgs }
        }

        var blocks: [AnyView] = [AnyView(pdfHeaderBlock(conversation))]
        for turn in conversation.turns {
            blocks.append(AnyView(ShareTurnCard(turn: turn, mode: conversation.mode,
                                                preloadedImages: map[turn.id] ?? [], capText: false)))
        }
        blocks.append(AnyView(pdfFooterBlock()))

        let pageW: CGFloat = 612, pageH: CGFloat = 792, margin: CGFloat = 28
        let contentW = pageW - margin * 2
        let contentH = pageH - margin * 2
        let gap: CGFloat = 10

        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else { return nil }
        var mediaBox = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        let canvas = CGColor(gray: 0.97, alpha: 1)

        func beginPage() {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(canvas)
            ctx.fill(mediaBox)
        }

        beginPage()
        var top = margin   // 当前块顶距页顶的偏移

        for block in blocks {
            await Task.yield()   // 两块之间让出主线程,渲染本身仍在主线程(ImageRenderer 要求)
            let renderer = ImageRenderer(content: block)
            var size: CGSize = .zero
            renderer.render { s, _ in size = s }
            guard size.width > 1, size.height > 1 else { continue }
            let s = min(1, contentW / size.width)
            let dispH = size.height * s

            if dispH <= contentH {
                if top + dispH > pageH - margin {   // 放不下 → 翻页(块不被切)
                    ctx.endPDFPage(); beginPage(); top = margin
                }
                let ty = pageH - top - dispH
                renderer.render { _, draw in
                    ctx.saveGState()
                    ctx.translateBy(x: margin, y: ty)
                    ctx.scaleBy(x: s, y: s)
                    draw(ctx)
                    ctx.restoreGState()
                }
                top += dispH + gap
            } else {
                // 单块比整页还高 → 从新页起,按页切(仅此情况会切到行)。
                if top > margin { ctx.endPDFPage(); beginPage(); top = margin }
                let pages = Int(ceil(dispH / contentH))
                for i in 0..<pages {
                    if i > 0 { ctx.endPDFPage(); beginPage() }
                    let ty = (pageH - margin) + CGFloat(i) * contentH - dispH
                    renderer.render { _, draw in
                        ctx.saveGState()
                        ctx.clip(to: CGRect(x: margin, y: margin, width: contentW, height: contentH))
                        ctx.translateBy(x: margin, y: ty)
                        ctx.scaleBy(x: s, y: s)
                        draw(ctx)
                        ctx.restoreGState()
                    }
                }
                top = margin + (dispH - CGFloat(pages - 1) * contentH) + gap
            }
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return pdfData as Data
    }

    /// PDF 首块:会话标题 + 模式 + 轮数。
    @MainActor
    private static func pdfHeaderBlock(_ conv: Conversation) -> some View {
        HStack(spacing: 10) {
            Image(systemName: conv.mode.symbol)
                .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(conv.title.isEmpty ? "Kown 会话" : conv.title)
                    .font(.system(.title3, design: .rounded).weight(.bold)).lineLimit(2)
                Text("\(conv.mode.displayName) · \(conv.turns.count) 轮")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 520, alignment: .leading)
    }

    @MainActor
    private static func pdfFooterBlock() -> some View {
        Text("via Kown")
            .font(.caption2).foregroundStyle(.secondary)
            .padding(12)
            .frame(width: 520, alignment: .leading)
    }

    /// 同步预加载某轮的用户附图(ImageRenderer 同步渲染,不能依赖异步 .task)。
    @MainActor
    private static func preloadImages(_ turn: Turn) -> [PlatformImage] {
        (turn.images ?? []).compactMap { meta in
            let url = ConversationImageStore.url(for: meta.fileName)
            guard let data = ConversationImageStore.loadData(at: url) else { return nil }
            return PlatformImage(data: data)
        }
    }

    /// 把渲染结果写进系统剪贴板。
    @MainActor
    private static func copy<V: View>(_ renderer: ImageRenderer<V>) -> Bool {
        // 先量一遍内容点尺寸,据此挑 scale。整会话长图很高,固定 scale=2 会让像素尺寸
        // 超过 CoreGraphics / Metal 的位图上限(~16384px),ImageRenderer 会直接产出**空白图**
        // (用户报「生成几轮对话时出空白图」即此)。把最长边的像素数压到安全预算内即可。
        var contentSize: CGSize = .zero
        renderer.render { size, _ in contentSize = size }
        // 位图单边上限约 16384px,贴着上限取(留点余量)以尽量保持 2× 清晰度;
        // 仅当内容确实过长(超长会话)才降到 2× 以下,避免空白。
        let maxPixels: CGFloat = 16000
        let longest = max(contentSize.width, contentSize.height)
        renderer.scale = longest > 0 ? min(2, maxPixels / longest) : 2
        #if os(macOS)
        guard let ns = renderer.nsImage else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([ns])
        #else
        guard let ui = renderer.uiImage else { return false }
        UIPasteboard.general.image = ui
        return true
        #endif
    }
}
