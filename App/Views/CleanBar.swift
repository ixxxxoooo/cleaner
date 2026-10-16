// 底部清理操作条、确认对话框、清理结果面板
// @author ygw
import SwiftUI
import CleanerCore

/// 底部浮动清理操作条（Liquid Glass 胶囊）
struct CleanBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if model.cleaning || !model.checkedItems.isEmpty {
            HStack(spacing: 14) {
                if model.cleaning, let progress = model.cleanProgress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .frame(width: 160)
                    Text("正在清理 \(progress.done)/\(progress.total)…")
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("已选 \(model.checkedItems.count) 项").font(.callout)
                        Text(formatBytes(model.checkedBytes))
                            .font(.title3.bold())
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    Spacer(minLength: 20)
                    Picker("清理方式", selection: $model.cleanMode) {
                        Text("移入废纸篓").tag(CleanMode.trash)
                        Text("永久删除").tag(CleanMode.permanent)
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .help("移入废纸篓可还原，清空废纸篓后才释放空间；永久删除不可恢复")
                    Button("取消选择") { model.clearSelection() }
                        .buttonStyle(.glass)
                    Button {
                        model.requestClean()
                    } label: {
                        Label(model.cleanMode == .trash ? "清理所选" : "永久删除", systemImage: model.cleanMode == .trash ? "trash" : "flame")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(model.cleanMode == .trash ? .accentColor : .red)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(maxWidth: 720)
            .background(.regularMaterial, in: .capsule)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, 12)
            .padding(.horizontal, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.snappy, value: model.checkedItems.isEmpty)
        }
    }
}

/// 清理相关对话框：确认、二次确认、结果面板
struct CleanDialogs: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .alert(
                firstTitle, isPresented: Binding(
                    get: { model.pendingClean?.stage == 1 },
                    set: { if !$0 && model.pendingClean?.stage == 1 { model.cancelClean() } })
            ) {
                Button(model.pendingClean?.mode == .trash ? "移入废纸篓" : "继续", role: model.pendingClean?.mode == .trash ? nil : .destructive) {
                    model.confirmClean()
                }
                Button("取消", role: .cancel) { model.cancelClean() }
            } message: {
                Text(firstMessage)
            }
            .alert(
                "最后确认：永久删除", isPresented: Binding(
                    get: { model.pendingClean?.stage == 2 },
                    set: { if !$0 && model.pendingClean?.stage == 2 { model.cancelClean() } })
            ) {
                Button("永久删除", role: .destructive) { model.confirmClean() }
                Button("取消", role: .cancel) { model.cancelClean() }
            } message: {
                Text("将立即永久删除 \(model.pendingClean?.items.count ?? 0) 项（\(formatBytes(model.pendingClean?.bytes ?? 0))），不经过废纸篓，无法恢复。")
            }
            .sheet(item: $model.cleanReport) { report in
                CleanReportView(report: report)
            }
    }

    private var firstTitle: String {
        guard let pending = model.pendingClean else { return "" }
        return pending.mode == .trash
            ? "将 \(pending.items.count) 项移入废纸篓？"
            : "永久删除 \(pending.items.count) 项？"
    }

    private var firstMessage: String {
        guard let pending = model.pendingClean else { return "" }
        var lines = [String]()
        if pending.mode == .trash {
            lines.append("共 \(formatBytes(pending.bytes))。文件会先移入废纸篓，可随时还原；清空废纸篓后才会真正释放磁盘空间。")
        } else {
            lines.append("共 \(formatBytes(pending.bytes))，将绕过废纸篓直接删除。")
        }
        if pending.networkCount > 0 {
            lines.append("其中 \(pending.networkCount) 项清理后需联网重新下载依赖，首次构建耗时会明显增加。")
        }
        if pending.cautionCount > 0 {
            lines.append("其中 \(pending.cautionCount) 项属于「需谨慎」等级，请确认已了解其影响。")
        }
        if pending.activeCount > 0 {
            lines.append("其中 \(pending.activeCount) 项属于近期仍在使用的项目。")
        }
        return lines.joined(separator: "\n")
    }
}

/// 清理完成面板
struct CleanReportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let report: CleanReport
    @State private var trashMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: report.outcome.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(report.outcome.failures.isEmpty ? .green : .orange)
                VStack(alignment: .leading) {
                    Text(report.mode == .trash ? "已移入废纸篓 \(formatBytes(report.outcome.freedBytes))" : "已永久删除 \(formatBytes(report.outcome.freedBytes))")
                        .font(.title2.bold())
                    Text("成功 \(report.outcome.records.count) 项\(report.outcome.failures.isEmpty ? "" : "，失败 \(report.outcome.failures.count) 项")")
                        .foregroundStyle(.secondary)
                }
            }
            if report.mode == .trash, !report.outcome.records.isEmpty {
                Label("空间尚未释放：清空废纸篓后才会真正回收磁盘空间。", systemImage: "info.circle")
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular, in: .rect(cornerRadius: 10))
            }
            if !report.outcome.failures.isEmpty {
                Text("失败详情").font(.headline)
                List(report.outcome.failures) { failure in
                    VStack(alignment: .leading) {
                        Text(failure.item.title)
                        Text(failure.message).font(.caption).foregroundStyle(.red)
                    }
                }
                .frame(height: 120)
            }
            if let trashMessage { Text(trashMessage).font(.caption).foregroundStyle(.red) }
            HStack {
                if report.mode == .trash, !report.outcome.records.isEmpty {
                    Button("打开废纸篓") { SystemActions.openTrash() }
                    Button("清空废纸篓") {
                        trashMessage = SystemActions.emptyTrash()
                        model.refreshDisk()
                        if trashMessage == nil { dismiss() }
                    }
                }
                Spacer()
                Button("好") { dismiss() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
