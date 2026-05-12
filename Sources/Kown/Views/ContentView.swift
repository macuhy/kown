import SwiftUI

struct ContentView: View {
    @Bindable var viewModel: CouncilViewModel
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            promptArea
            Divider()
            responsesArea
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSettings = true
                } label: {
                    Label("配置", systemImage: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(viewModel: viewModel)
                .frame(minWidth: 720, minHeight: 520)
        }
    }

    @State private var showSystemPrompt = false

    private var promptArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Prompt").font(.headline)
                Spacer()
                Button {
                    showSystemPrompt.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showSystemPrompt ? "chevron.down" : "chevron.right")
                        Text(viewModel.systemPrompt.isEmpty ? "System Prompt" : "System Prompt ✓")
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderless)
                enabledSummary
            }

            if showSystemPrompt {
                TextEditor(text: $viewModel.systemPrompt)
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3))
                    )
                    .cornerRadius(8)
                    .frame(minHeight: 60, maxHeight: 120)
            }

            TextEditor(text: $viewModel.prompt)
                .font(.system(.body, design: .default))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3))
                )
                .cornerRadius(8)
                .frame(minHeight: 80, maxHeight: 160)

            HStack {
                Spacer()
                if viewModel.isRunning {
                    Button(role: .destructive) {
                        viewModel.cancel()
                    } label: {
                        Label("取消", systemImage: "stop.circle")
                    }
                }
                Button {
                    viewModel.send()
                } label: {
                    Label("并发发送", systemImage: "paperplane.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(activeCount == 0 || viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
    }

    private var enabledSummary: some View {
        let active = activeCount
        let total = viewModel.providers.count
        return Text("\(active) / \(total) 启用")
            .font(.caption)
            .foregroundStyle(active == 0 ? .red : .secondary)
    }

    private var activeCount: Int {
        viewModel.providers.filter(\.enabled).count
    }

    private var responsesArea: some View {
        Group {
            if activeCount == 0 {
                ContentUnavailableView {
                    Label("没有启用的厂商", systemImage: "exclamationmark.bubble")
                } description: {
                    Text("点击右上角齿轮添加并启用厂商,填入 Base URL 和 API Key。")
                }
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(viewModel.providers.filter(\.enabled)) { cfg in
                            if let state = viewModel.states[cfg.id] {
                                ResponseColumnView(config: cfg, state: state)
                                    .frame(width: 360)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
    }
}
