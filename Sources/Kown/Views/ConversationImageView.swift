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
