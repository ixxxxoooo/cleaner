// 右侧详情：判定依据、清理影响、网络重下载提示、仅展示项的引导命令
// @author ygw
import SwiftUI
import CleanerCore

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let item = model.focusedItem {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(item)
                    facts(item)
                    section("识别依据", item.reason)
                    impact(item)
                    if let guide = item.guide { guideBox(guide) }
                    actions(item)
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView("选择一项查看详情", systemImage: "info.circle", description: Text("在列表或树图中点击任意项目"))
        }
    }

    private func header(_ item: ScanItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(item.stack.color).frame(width: 10, height: 10)
                Text(item.stack.displayName).font(.caption).foregroundStyle(.secondary)
                Spacer()
                LevelBadge(level: item.level)
            }
            Text(item.title).font(.title3.bold()).textSelection(.enabled)
            Text(item.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private func facts(_ item: ScanItem) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow { Text("占用").foregroundStyle(.secondary); Text(formatBytes(item.sizeBytes)).monospacedDigit().bold() }
            GridRow { Text("文件数").foregroundStyle(.secondary); Text("\(item.fileCount)").monospacedDigit() }
            GridRow { Text("规则").foregroundStyle(.secondary); Text(item.ruleName) }
            if let project = item.projectPath {
                GridRow { Text("所属项目").foregroundStyle(.secondary); Text((project as NSString).abbreviatingWithTildeInPath).lineLimit(2).truncationMode(.middle) }
            }
            GridRow {
                Text(item.scope == .project ? "源码最近修改" : "最近修改").foregroundStyle(.secondary)
                if let date = item.lastActivity {
                    Text("\(date.formatted(date: .abbreviated, time: .omitted))（闲置 \(item.idleText)）")
                } else {
                    Text("未知")
                }
            }
            if item.isDormant {
                GridRow { Text("状态").foregroundStyle(.secondary); Label("休眠项目", systemImage: "moon.zzz").foregroundStyle(.green) }
            } else if item.isActiveProject {
                GridRow { Text("状态").foregroundStyle(.secondary); Label("近期在用", systemImage: "bolt.fill").foregroundStyle(.orange) }
            }
        }
        .font(.callout)
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 清理影响与网络提示
    private func impact(_ item: ScanItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            section("清理影响", item.regenNote)
            if item.requiresNetwork {
                Label("清理后再次构建需要联网重新下载，耗时取决于网络与依赖规模。", systemImage: "network")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if item.isActiveProject {
                Label("该项目最近仍有修改，清理后下次构建会变慢。", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 仅展示项的操作引导
    private func guideBox(_ guide: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("建议操作").font(.headline)
            Text(guide).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            Button("复制命令") { SystemActions.copy(guide) }.buttonStyle(.glass)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private func actions(_ item: ScanItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.isCleanable {
                Button {
                    model.toggle(item)
                } label: {
                    Label(model.isChecked(item) ? "取消勾选" : "加入清理清单", systemImage: model.isChecked(item) ? "minus.circle" : "plus.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            }
            HStack {
                Button("在 Finder 中显示") { SystemActions.reveal(item.path) }
                Button("加入白名单") { model.whitelist(item: item) }
            }
            .buttonStyle(.glass)
        }
    }
}
