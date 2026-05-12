import SwiftUI

struct ResponseColumnView: View {
    let config: ProviderConfig
    @Bindable var state: ResponseState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            body_
            Divider()
            footer
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.gray.opacity(0.25))
        )
        .cornerRadius(10)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(phaseColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(config.displayName).font(.headline)
                Text(config.model).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var body_: some View {
        ScrollView {
            switch state.phase {
            case .idle:
                Text("等待发送…").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .streaming, .finished:
                Text(state.text.isEmpty ? "…" : state.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minHeight: 260)
    }

    private var footer: some View {
        HStack {
            if let s = state.elapsedSeconds {
                Text(String(format: "%.1fs", s))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(state.text, forType: .string)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .disabled(state.text.isEmpty)
        }
    }

    private var phaseColor: Color {
        switch state.phase {
        case .idle:      return .gray
        case .streaming: return .blue
        case .finished:  return .green
        case .failed:    return .red
        }
    }
}
