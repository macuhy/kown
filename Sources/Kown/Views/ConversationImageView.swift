import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 渲染对话里的一张图片缩略图。
/// 从 `ConversationImageStore` 异步加载;对端首次是 iCloud 占位文件时触发下载并轮询重试。
/// 点击放大全屏查看。
struct ConversationImageView: View {
    let image: TurnImage
    var maxThumb: CGFloat = 150

    @State private var data: Data?
    @State private var failed = false
    @State private var showFull = false

    private var aspect: CGFloat {
        guard image.pixelWidth > 0, image.pixelHeight > 0 else { return 1 }
        return CGFloat(image.pixelWidth) / CGFloat(image.pixelHeight)
    }
    private var thumbW: CGFloat { aspect >= 1 ? maxThumb : max(48, maxThumb * aspect) }
    private var thumbH: CGFloat { aspect >= 1 ? max(48, maxThumb / aspect) : maxThumb }

    var body: some View {
        content
            .frame(width: thumbW, height: thumbH)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture { if data != nil { showFull = true } }
            .task(id: image.fileName) { await load() }
            .sheet(isPresented: $showFull) { fullScreen }
    }

    @ViewBuilder
    private var content: some View {
        if let data, let img = Self.makeImage(from: data) {
            img.resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.12))
                if failed {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private var fullScreen: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let data, let img = Self.makeImage(from: data) {
                img.resizable().aspectRatio(contentMode: .fit)
            }
            VStack {
                HStack {
                    Spacer()
                    Button { showFull = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(12)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 360)
        #endif
        .onTapGesture { showFull = false }
    }

    private func load() async {
        failed = false
        data = nil
        // 重试几次,给 iCloud 下载占位文件留时间。
        for attempt in 0..<12 {
            let url = ConversationImageStore.url(for: image.fileName)
            if let d = await Task.detached(priority: .utility, operation: {
                ConversationImageStore.loadData(at: url)
            }).value {
                data = d
                return
            }
            // 第一次读会触发下载;之后等一会儿再试。
            try? await Task.sleep(for: .seconds(attempt < 3 ? 0.4 : 1.0))
        }
        failed = true
    }

    static func makeImage(from data: Data) -> Image? {
        #if os(macOS)
        guard let ns = NSImage(data: data) else { return nil }
        return Image(nsImage: ns)
        #else
        guard let ui = UIImage(data: data) else { return nil }
        return Image(uiImage: ui)
        #endif
    }
}

/// 一行水平排列的对话图片缩略图(PromptBubble / 用户气泡里复用)。
struct ConversationImagesRow: View {
    let images: [TurnImage]

    var body: some View {
        if !images.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(images) { img in
                        ConversationImageView(image: img)
                    }
                }
            }
        }
    }
}

/// 图像生成对比:多个模型用同一 prompt 各自出图,按模型分组并排展示。
/// 每个模型一张卡片:头部是模型名 + model,下面是它出的图(横向缩略图)或失败原因。
struct GeneratedImageComparison: View {
    /// 渲染顺序的 providerID(uuidString);来自 `Turn.panelOrder`。
    let order: [String]
    /// providerID → provider 快照(取名字 / model 展示)。来自 `Turn.providerSnapshot`。
    let snapshot: [String: ProviderConfig]
    /// providerID → 该模型出的图。
    let imagesByProvider: [String: [TurnImage]]
    /// providerID → 该模型失败原因。
    let errors: [String: String]

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: 12, alignment: .top)]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(order, id: \.self) { pid in
                card(pid: pid)
            }
        }
    }

    @ViewBuilder
    private func card(pid: String) -> some View {
        let cfg = snapshot[pid]
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "photo.artframe")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(cfg?.displayName ?? "模型")
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                if let model = cfg?.model, !model.isEmpty {
                    Text(model)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            if let imgs = imagesByProvider[pid], !imgs.isEmpty {
                ConversationImagesRow(images: imgs)
            } else if let err = errors[pid] {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.red.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Text("(无图片)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.platformControlBackground.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }
}
