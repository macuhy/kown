import SwiftUI

struct ModelDoctorView: View {
    @Bindable var viewModel: AppViewModel

    private let tint = Color(red: 0.10, green: 0.66, blue: 0.56)

    private var reports: [ModelHealthReport] {
        viewModel.providers.compactMap { viewModel.modelHealthReports[$0.id] }
    }

    private var readyCount: Int {
        reports.filter(\.isHealthy).count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                summaryGrid
                quickFixCard
                providerList
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .topLeading)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    titleBlock
                    Spacer(minLength: 10)
                    actions
                }
                VStack(alignment: .leading, spacing: 12) {
                    titleBlock
                    actions
                }
            }
            Text("自动检查 Base URL、API Key、CLI 命令、ping 延迟和典型错误,帮你把模型配置从“能填”变成“能用”。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 1)
        }
    }

    private var titleBlock: some View {
        HStack(spacing: 12) {
            Image(systemName: "stethoscope")
                .font(.title2.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("模型体检 / 自动配置向导")
                    .font(.title3.weight(.bold))
                Text("\(readyCount)/\(viewModel.providers.count) 家最近体检可用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                viewModel.runModelHealthChecks(enabledOnly: true)
            } label: {
                Label("体检已启用", systemImage: "checkmark.seal")
            }
            .disabled(viewModel.modelHealthBatchRunning || viewModel.providers.filter(\.enabled).isEmpty)
            Button {
                viewModel.runModelHealthChecks(enabledOnly: false)
            } label: {
                if viewModel.modelHealthBatchRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Label("全部体检", systemImage: "bolt.heart")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .disabled(viewModel.modelHealthBatchRunning || viewModel.providers.isEmpty)
        }
    }

    private var summaryGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            metric("Provider", value: "\(viewModel.providers.count)", detail: "已保存配置", icon: "square.stack.3d.up", color: tint)
            metric("已启用", value: "\(viewModel.providers.filter(\.enabled).count)", detail: "会参与发送", icon: "power", color: .green)
            metric("体检可用", value: "\(readyCount)", detail: "最近一次成功/警告", icon: "heart.text.square", color: readyCount == 0 ? .orange : .green)
            metric("失败", value: "\(reports.filter { $0.status == .failed }.count)", detail: "需修复后重测", icon: "exclamationmark.triangle", color: .red)
        }
    }

    private func metric(_ title: String, value: String, detail: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(value).font(.title3.weight(.bold)).monospacedDigit()
            Text(title).font(.caption.weight(.bold)).foregroundStyle(.secondary)
            Text(detail).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var quickFixCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("推荐修复顺序", systemImage: "wand.and.stars")
                .font(.headline)
                .foregroundStyle(tint)
            fixRow("1", "先体检已启用模型", "确认当前发送链路可用,避免 Council 卡在坏配置。")
            fixRow("2", "修复失败项", "401 查 Key,404 查模型名/Base URL,429 查限流。")
            fixRow("3", "保留至少一家备用模型", "把便宜快模型设为 Direct,旗舰模型设为 Chair 或升级候选。")
        }
        .padding(16)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.16), lineWidth: 1)
        }
    }

    private func fixRow(_ num: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(num)
                .font(.caption2.weight(.black))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(tint, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var providerList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("逐项结果")
                .font(.headline)
            if viewModel.providers.isEmpty {
                Text("还没有 Provider。请先到「厂商」添加模型。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.providers) { provider in
                    providerRow(provider)
                }
            }
        }
    }

    private func providerRow(_ provider: ProviderConfig) -> some View {
        let report = viewModel.modelHealthReports[provider.id]
        let running = viewModel.modelHealthRunning.contains(provider.id)
        let color = colorFor(report?.status)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: provider.kownSymbol)
                    .foregroundStyle(color)
                    .frame(width: 34, height: 34)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.displayName)
                        .font(.callout.weight(.semibold))
                    Text("\(provider.kind.displayName) · \(provider.model)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                statusPill(report, running: running)
                Button {
                    viewModel.runModelHealthCheck(for: provider.id)
                } label: {
                    if running { ProgressView().controlSize(.small) }
                    else { Label("体检", systemImage: "bolt.horizontal.circle") }
                }
                .buttonStyle(.bordered)
                .disabled(running)
            }
            if let report {
                if let latency = report.latencyMS {
                    Text("延迟 \(latency) ms · 样例: \(report.sample.isEmpty ? "(空响应)" : report.sample)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                ForEach(report.suggestions, id: \.self) { suggestion in
                    Label(suggestion, systemImage: report.status == .failed ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(.caption)
                        .foregroundStyle(report.status == .failed ? .orange : .secondary)
                }
            } else {
                Text("尚未体检。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(color.opacity(0.16), lineWidth: 1)
        }
    }

    private func statusPill(_ report: ModelHealthReport?, running: Bool) -> some View {
        let title = running ? "体检中" : (report?.status.displayName ?? "未体检")
        let color = running ? tint : colorFor(report?.status)
        return Text(title)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
            .fixedSize()
    }

    private func colorFor(_ status: ModelHealthReport.Status?) -> Color {
        switch status {
        case .ready: return .green
        case .warning: return .orange
        case .failed: return .red
        case .skipped: return .secondary
        case nil: return .secondary
        }
    }
}
