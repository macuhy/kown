import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: CouncilViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("厂商配置").font(.title2).bold()
                Spacer()
                Menu {
                    ForEach(ProviderKind.allCases) { kind in
                        Button("添加 \(kind.displayName)") {
                            viewModel.addProvider(kind: kind)
                        }
                    }
                } label: {
                    Label("添加", systemImage: "plus")
                }
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    ForEach($viewModel.providers) { $cfg in
                        ProviderRowView(config: $cfg,
                                        onDelete: { viewModel.removeProvider(cfg.id) },
                                        onSave: { viewModel.saveProviders() })
                    }
                }
                .padding()
            }
        }
    }
}
