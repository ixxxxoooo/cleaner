// 仪表盘：指标卡 + 技术栈环形图 + 矩形树图，一眼看清磁盘占用
// @author ygw
import SwiftUI
import Charts
import CleanerCore

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.items.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 16) {
                    metrics
                    // 宽度不足时自动改为上下排列，避免内容最小宽度超过窗口导致布局循环
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            StackDonutCard().frame(width: 330)
                            TreemapCard().frame(minWidth: 420)
                        }
                        VStack(spacing: 16) {
                            StackDonutCard()
                            TreemapCard()
                        }
                    }
                    topList
                }
                .padding(16)
            }
        }
    }

    /// 空状态
    @ViewBuilder
    private var emptyState: some View {
        if model.phase == .scanning {
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("正在扫描…").font(.title3)
                Text("已访问 \(model.progress?.visitedDirectories ?? 0) 个目录").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("没有发现可清理的内容", systemImage: "sparkles")
            } description: {
                Text("点击右上角「开始扫描」，分析主目录下的构建产物与依赖缓存。")
            } actions: {
                Button("开始扫描") { model.startScan() }.buttonStyle(.glassProminent)
            }
        }
    }

    /// 指标卡
    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
            MetricCard(title: "可回收总量", value: formatBytes(model.totalBytes), caption: "\(model.items.count) 项", symbol: "externaldrive.fill", tint: .blue)
            MetricCard(title: "极力推荐", value: formatBytes(model.recommendedBytes), caption: "休眠项目 / 已废弃工程", symbol: "sparkles", tint: .green)
            MetricCard(title: "磁盘剩余", value: formatBytes(model.freeBytes), caption: "共 \(formatBytes(model.diskTotalBytes))", symbol: "internaldrive", tint: .orange)
            MetricCard(title: "已勾选", value: formatBytes(model.checkedBytes), caption: "\(model.checkedItems.count) 项待清理", symbol: "checkmark.circle.fill", tint: .purple)
        }
    }

    /// 最大的 8 项快速列表
    private var topList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("占用最大的项目").font(.headline)
                Spacer()
                Button("一键勾选「极力推荐」") { model.selectRecommended() }
                    .disabled(model.recommendedBytes == 0)
                    .buttonStyle(.glass)
            }
            ForEach(model.items.prefix(8)) { item in
                TopRow(item: item, maxBytes: model.items.first?.sizeBytes ?? 1)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

/// 指标卡
struct MetricCard: View {
    let title: String
    let value: String
    let caption: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).foregroundStyle(.secondary)
                Text(value).font(.title2.bold()).monospacedDigit().contentTransition(.numericText())
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

/// 快速列表行：点击勾选，右侧体积条
struct TopRow: View {
    @Environment(AppModel.self) private var model
    let item: ScanItem
    let maxBytes: Int64
    /// 分组列表中项目名已在组头，行内只显示目录名
    var compactTitle = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { model.isChecked(item) }, set: { _ in model.toggle(item) }))
                .labelsHidden()
                .disabled(!item.isCleanable)
            VStack(alignment: .leading, spacing: 1) {
                Text(compactTitle && item.scope == .project ? item.name : item.title).lineLimit(1)
                Text(item.shortPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            LevelBadge(level: item.level)
            SizeBar(bytes: item.sizeBytes, maxBytes: maxBytes, tint: item.stack.color)
                .frame(minWidth: 120, idealWidth: 220, maxWidth: 220)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.focusedID = item.id }
    }
}

/// 体积条：数字 + 比例条
struct SizeBar: View {
    let bytes: Int64
    let maxBytes: Int64
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: Double(bytes), total: Double(max(maxBytes, 1)))
                .tint(tint)
            Text(formatBytes(bytes))
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
        }
    }
}

/// 等级徽章
struct LevelBadge: View {
    let level: CleanLevel

    var body: some View {
        Label(level.title, systemImage: level.symbol)
            .font(.caption)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(level.color)
            .background(level.color.opacity(0.15), in: Capsule())
    }
}

/// 技术栈环形图卡片
struct StackDonutCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("按技术栈占比").font(.headline)
            Chart(model.stackTotals) { entry in
                SectorMark(angle: .value("体积", entry.bytes), innerRadius: .ratio(0.62), angularInset: 1.5)
                    .cornerRadius(4)
                    .foregroundStyle(entry.stack.color)
            }
            .chartLegend(.hidden)
            .frame(height: 210)
            .overlay {
                VStack(spacing: 0) {
                    Text(formatBytes(model.totalBytes)).font(.title3.bold()).monospacedDigit()
                    Text("可回收").font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 6) {
                ForEach(model.stackTotals.prefix(9)) { entry in
                    HStack(spacing: 8) {
                        Circle().fill(entry.stack.color).frame(width: 9, height: 9)
                        Text(entry.stack.displayName).lineLimit(1)
                        Spacer()
                        Text("\(entry.count)").foregroundStyle(.secondary).font(.caption)
                        Text(formatBytes(entry.bytes)).monospacedDigit().frame(width: 76, alignment: .trailing)
                    }
                    .font(.callout)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

/// 树图卡片
struct TreemapCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("空间分布（面积 = 体积，点击勾选）").font(.headline)
                Spacer()
                ForEach(CleanLevel.allCases.filter { $0 != .safe }, id: \.self) { level in
                    HStack(spacing: 4) {
                        Circle().fill(level.color).frame(width: 8, height: 8)
                        Text(level.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            TreemapView(items: Array(model.items.prefix(180)))
                .frame(height: 400)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}
