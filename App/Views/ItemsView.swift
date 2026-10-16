// 结果列表：Table（平铺）或按项目/技术栈分组
// @author ygw
import SwiftUI
import CleanerCore

struct ItemsView: View {
    @Environment(AppModel.self) private var model
    let scope: RuleScope
    @State private var sortOrder = [KeyPathComparator(\ScanItem.sizeBytes, order: .reverse)]

    private var rows: [ScanItem] { model.filtered(scope: scope).sorted(using: sortOrder) }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            header(rows)
            if rows.isEmpty {
                empty
            } else if model.grouped {
                GroupedItemsList(items: rows, scope: scope)
            } else {
                table(rows)
            }
        }
    }

    /// 顶部筛选条
    private func header(_ rows: [ScanItem]) -> some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            Picker("等级", selection: $model.levelFilter) {
                ForEach(LevelFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            Toggle(scope == .project ? "按项目归类" : "按技术栈归类", isOn: $model.grouped)
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
            Spacer()
            Text("\(rows.count) 项 · \(formatBytes(rows.reduce(0) { $0 + $1.sizeBytes }))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("勾选「极力推荐」") { model.select(rows.filter { $0.level == .recommended }) }
                .disabled(!rows.contains { $0.level == .recommended })
            Button("勾选全部可见") { model.select(rows) }
                .disabled(rows.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var empty: some View {
        if model.phase == .scanning {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在扫描…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "没有符合条件的项目", systemImage: "tray",
                description: Text(model.items.isEmpty ? "点击「开始扫描」查找可清理的内容" : "试试调整筛选条件或搜索词"))
        }
    }

    /// 平铺表格
    private func table(_ rows: [ScanItem]) -> some View {
        let maxBytes = rows.map(\.sizeBytes).max() ?? 1
        return Table(rows, selection: Binding(get: { model.focusedID }, set: { model.focusedID = $0 }), sortOrder: $sortOrder) {
            TableColumn("") { item in
                Toggle("", isOn: Binding(get: { model.isChecked(item) }, set: { _ in model.toggle(item) }))
                    .labelsHidden()
                    .disabled(!item.isCleanable)
            }
            .width(26)
            TableColumn("目录", value: \.title) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).lineLimit(1)
                    Text(item.shortPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 220, ideal: 380)
            TableColumn("体积", value: \.sizeBytes) { item in
                SizeBar(bytes: item.sizeBytes, maxBytes: maxBytes, tint: item.stack.color)
            }
            .width(min: 150, ideal: 200)
            TableColumn("技术栈", value: \.stack.rawValue) { item in
                StackTag(stack: item.stack)
            }
            .width(min: 90, ideal: 110)
            TableColumn("闲置", value: \.idleSortKey) { item in
                Text(item.idleText).foregroundStyle(item.isDormant ? .green : .secondary)
            }
            .width(min: 60, ideal: 70)
            TableColumn("建议", value: \.level) { item in
                LevelBadge(level: item.level)
            }
            .width(min: 90, ideal: 100)
        }
        .contextMenu(forSelectionType: ScanItem.ID.self) { ids in
            ItemContextMenu(ids: ids)
        } primaryAction: { ids in
            if let id = ids.first, let item = model.items.first(where: { $0.id == id }) { SystemActions.reveal(item.path) }
        }
    }
}

/// 技术栈标签
struct StackTag: View {
    let stack: TechStack

    var body: some View {
        Text(stack.displayName)
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(stack.color.opacity(0.18), in: Capsule())
            .foregroundStyle(stack.color)
            .lineLimit(1)
    }
}

/// 右键菜单
struct ItemContextMenu: View {
    @Environment(AppModel.self) private var model
    let ids: Set<ScanItem.ID>

    var body: some View {
        let selected = model.items.filter { ids.contains($0.id) }
        if let first = selected.first {
            Button("在 Finder 中显示") { SystemActions.reveal(first.path) }
            Button("复制路径") { SystemActions.copy(selected.map(\.path).joined(separator: "\n")) }
            Divider()
            if selected.contains(where: \.isCleanable) {
                Button("勾选") { model.select(selected) }
                Button("取消勾选") { selected.forEach { model.checked.remove($0.id) } }
            }
            Divider()
            Button("加入白名单（不再扫描）") { selected.forEach { model.whitelist(item: $0) } }
        }
    }
}

/// 分组项
private struct ItemGroup: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let tint: Color
    let items: [ScanItem]
    var bytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }
}

/// 分组列表：项目级按项目，全局级按技术栈
struct GroupedItemsList: View {
    @Environment(AppModel.self) private var model
    let items: [ScanItem]
    let scope: RuleScope

    private var groups: [ItemGroup] {
        if scope == .project {
            return Dictionary(grouping: items) { $0.projectPath ?? $0.path }
                .map { key, list in
                    ItemGroup(id: key, title: (key as NSString).lastPathComponent,
                              subtitle: (key as NSString).abbreviatingWithTildeInPath,
                              tint: list.first?.stack.color ?? .gray, items: list)
                }
                .sorted { $0.bytes > $1.bytes }
        }
        return Dictionary(grouping: items) { $0.stack }
            .map { stack, list in
                ItemGroup(id: stack.rawValue, title: stack.displayName, subtitle: "\(list.count) 项", tint: stack.color, items: list)
            }
            .sorted { $0.bytes > $1.bytes }
    }

    var body: some View {
        let maxBytes = items.map(\.sizeBytes).max() ?? 1
        List(selection: Binding(get: { model.focusedID }, set: { model.focusedID = $0 })) {
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { item in
                        TopRow(item: item, maxBytes: maxBytes, compactTitle: true).tag(item.id)
                    }
                } header: {
                    HStack {
                        Circle().fill(group.tint).frame(width: 9, height: 9)
                        Text(group.title).font(.headline)
                        Text(group.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(formatBytes(group.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        Button("勾选本组") { model.select(group.items) }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}
