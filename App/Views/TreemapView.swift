// 矩形树图：Canvas 自绘（squarified），点击勾选，悬停显示详情
// 性能要点：布局结果按（数据签名 + 尺寸）缓存；鼠标位置只驱动提示气泡，不会触发树图重新布局与重绘
// @author ygw
import SwiftUI
import Observation
import CleanerCore

/// 悬停状态（独立的 Observable，只有读取它的子视图会刷新）
@MainActor
@Observable
final class TreemapHover {
    var id: String?
    var point: CGPoint = .zero
}

/// 布局缓存（引用类型，非 Observable，修改不会触发视图刷新）
@MainActor
final class TreemapLayoutCache {
    private var signature = ""
    private(set) var cells: [TreemapCell] = []
    private(set) var lookup: [String: ScanItem] = [:]
    private(set) var rects: [String: CGRect] = [:]

    /// 获取布局：数据与尺寸都未变化时直接复用
    func resolve(items: [ScanItem], size: CGSize) {
        var hasher = Hasher()
        hasher.combine(items.count)
        hasher.combine(Int(size.width))
        hasher.combine(Int(size.height))
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.sizeBytes)
            hasher.combine(item.level)
        }
        let newSignature = String(hasher.finalize())
        guard newSignature != signature else { return }
        signature = newSignature
        cells = TreemapLayout.layout(
            items.map { TreemapInput(id: $0.id, value: Double($0.sizeBytes)) },
            in: CGRect(origin: .zero, size: size))
        lookup = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        rects = Dictionary(cells.map { ($0.id, $0.rect) }, uniquingKeysWith: { first, _ in first })
    }
}

struct TreemapView: View {
    @Environment(AppModel.self) private var model
    let items: [ScanItem]
    @State private var hover = TreemapHover()
    @State private var cache = TreemapLayoutCache()

    var body: some View {
        GeometryReader { proxy in
            let _ = cache.resolve(items: items, size: proxy.size)
            ZStack(alignment: .topLeading) {
                TreemapCanvas(
                    cells: cache.cells, lookup: cache.lookup, checked: model.checked, focusedID: model.focusedID)
                TreemapHoverLayer(hover: hover, rects: cache.rects)
                TreemapTooltip(hover: hover, lookup: cache.lookup, size: proxy.size)
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("空间分布树图，共 \(items.count) 项，面积代表体积")
            .accessibilityHint("点击色块可勾选或取消勾选对应目录")
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hover.point = point
                    let id = cache.cells.last { $0.rect.contains(point) }?.id
                    if id != hover.id { hover.id = id }
                case .ended:
                    if hover.id != nil { hover.id = nil }
                }
            }
            .onTapGesture(count: 1, coordinateSpace: .local) { point in
                guard let id = cache.cells.last(where: { $0.rect.contains(point) })?.id,
                      let item = cache.lookup[id] else { return }
                model.focusedID = id
                model.toggle(item)
            }
        }
    }
}

/// 悬停高亮层（仅在悬停目标变化时重绘一个矩形）
private struct TreemapHoverLayer: View {
    let hover: TreemapHover
    let rects: [String: CGRect]

    var body: some View {
        Canvas { context, _ in
            guard let id = hover.id, let rect = rects[id]?.insetBy(dx: 1, dy: 1) else { return }
            let shape = Path(roundedRect: rect, cornerRadius: min(5, rect.width / 3, rect.height / 3))
            context.fill(shape, with: .color(.white.opacity(0.22)))
            context.stroke(shape, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }
}

/// 悬停提示气泡（只有它会随鼠标位置刷新）
private struct TreemapTooltip: View {
    let hover: TreemapHover
    let lookup: [String: ScanItem]
    let size: CGSize

    var body: some View {
        if let id = hover.id, let item = lookup[id] {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.callout.bold())
                Text("\(formatBytes(item.sizeBytes)) · \(item.stack.displayName) · \(item.level.title)").font(.caption)
                Text(item.shortPath).font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
            .background(.regularMaterial, in: .rect(cornerRadius: 10))
            .fixedSize()
            .offset(
                x: min(hover.point.x + 14, max(0, size.width - 280)),
                y: min(hover.point.y + 14, max(0, size.height - 70)))
            .allowsHitTesting(false)
        }
    }
}

/// 树图画布（输入全部以值传递，保证状态变化时重绘）
struct TreemapCanvas: View {
    let cells: [TreemapCell]
    let lookup: [String: ScanItem]
    let checked: Set<String>
    let focusedID: String?

    var body: some View {
        Canvas { context, _ in
            for cell in cells {
                guard let item = lookup[cell.id] else { continue }
                let rect = cell.rect.insetBy(dx: 1, dy: 1)
                guard rect.width > 1, rect.height > 1 else { continue }
                let shape = Path(roundedRect: rect, cornerRadius: min(5, rect.width / 3, rect.height / 3))
                let isChecked = checked.contains(cell.id)
                let opacity: Double = switch item.level {
                case .recommended: 0.95
                case .safe: 0.78
                case .caution: 0.58
                case .displayOnly: 0.32
                }
                context.fill(shape, with: .color(item.stack.color.opacity(opacity)))

                if isChecked {
                    context.stroke(shape, with: .color(.white), lineWidth: 3)
                } else if cell.id == focusedID {
                    context.stroke(shape, with: .color(.primary), lineWidth: 2)
                }

                // 只给足够大的色块绘制文字，避免成百上千个小块的文字排版开销
                if rect.width > 64, rect.height > 34 {
                    var clipped = context
                    clipped.clip(to: Path(rect.insetBy(dx: 4, dy: 3)))
                    // 文字带轻微阴影，黄色/橙色底上也清晰
                    clipped.addFilter(.shadow(color: .black.opacity(0.5), radius: 1.5, x: 0, y: 0.5))
                    let name = Text(item.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    let size = Text(formatBytes(item.sizeBytes)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.95))
                    clipped.draw(name, at: CGPoint(x: rect.minX + 6, y: rect.minY + 5), anchor: .topLeading)
                    clipped.draw(size, at: CGPoint(x: rect.minX + 6, y: rect.minY + 20), anchor: .topLeading)
                }
                // 等级角标
                if item.level == .recommended || item.level == .caution, rect.width > 22, rect.height > 22 {
                    let dot = CGRect(x: rect.maxX - 13, y: rect.minY + 5, width: 8, height: 8)
                    context.fill(Path(ellipseIn: dot), with: .color(item.level.color))
                    context.stroke(Path(ellipseIn: dot), with: .color(.white), lineWidth: 1.2)
                }
                // 勾选标记
                if isChecked, rect.width > 26, rect.height > 26 {
                    let badge = CGRect(x: rect.maxX - 22, y: rect.maxY - 22, width: 16, height: 16)
                    context.fill(Path(ellipseIn: badge), with: .color(.white))
                    var tick = Path()
                    tick.move(to: CGPoint(x: badge.minX + 4, y: badge.midY))
                    tick.addLine(to: CGPoint(x: badge.minX + 7, y: badge.midY + 3))
                    tick.addLine(to: CGPoint(x: badge.maxX - 3.5, y: badge.minY + 4.5))
                    context.stroke(tick, with: .color(.blue), lineWidth: 2)
                }
            }
        }
    }
}
