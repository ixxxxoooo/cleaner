// 矩形树图：Canvas 自绘（squarified），点击勾选，悬停显示详情
// @author ygw
import SwiftUI
import CleanerCore

struct TreemapView: View {
    @Environment(AppModel.self) private var model
    let items: [ScanItem]
    @State private var hoverID: String?
    @State private var hoverPoint: CGPoint = .zero

    var body: some View {
        GeometryReader { proxy in
            let cells = TreemapLayout.layout(
                items.map { TreemapInput(id: $0.id, value: Double($0.sizeBytes)) },
                in: CGRect(origin: .zero, size: proxy.size))
            let lookup = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            ZStack(alignment: .topLeading) {
                TreemapCanvas(
                    cells: cells, lookup: lookup, checked: model.checked,
                    focusedID: model.focusedID, hoverID: hoverID)
                if let hoverID, let item = lookup[hoverID] {
                    tooltip(for: item, in: proxy.size)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("空间分布树图，共 \(items.count) 项，面积代表体积")
            .accessibilityHint("点击色块可勾选或取消勾选对应目录")
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hoverPoint = point
                    hoverID = cells.last { $0.rect.contains(point) }?.id
                case .ended:
                    hoverID = nil
                }
            }
            .onTapGesture(count: 1, coordinateSpace: .local) { point in
                guard let id = cells.last(where: { $0.rect.contains(point) })?.id, let item = lookup[id] else { return }
                model.focusedID = id
                model.toggle(item)
            }
        }
    }

    /// 悬停提示
    private func tooltip(for item: ScanItem, in size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).font(.callout.bold())
            Text("\(formatBytes(item.sizeBytes)) · \(item.stack.displayName) · \(item.level.title)").font(.caption)
            Text(item.shortPath).font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
        .fixedSize()
        .offset(
            x: min(hoverPoint.x + 14, max(0, size.width - 280)),
            y: min(hoverPoint.y + 14, max(0, size.height - 70)))
        .allowsHitTesting(false)
    }
}

/// 树图画布（输入全部以值传递，保证状态变化时重绘）
struct TreemapCanvas: View {
    let cells: [TreemapCell]
    let lookup: [String: ScanItem]
    let checked: Set<String>
    let focusedID: String?
    let hoverID: String?

    var body: some View {
        Canvas { context, _ in
            for cell in cells {
                guard let item = lookup[cell.id] else { continue }
                let rect = cell.rect.insetBy(dx: 1, dy: 1)
                guard rect.width > 1, rect.height > 1 else { continue }
                let shape = Path(roundedRect: rect, cornerRadius: min(5, rect.width / 3, rect.height / 3))
                let isChecked = checked.contains(cell.id)
                var opacity: Double = switch item.level {
                case .recommended: 0.95
                case .safe: 0.78
                case .caution: 0.58
                case .displayOnly: 0.32
                }
                if cell.id == hoverID { opacity = min(1, opacity + 0.15) }
                context.fill(shape, with: .color(item.stack.color.opacity(opacity)))

                if isChecked {
                    context.stroke(shape, with: .color(.white), lineWidth: 3)
                } else if cell.id == focusedID {
                    context.stroke(shape, with: .color(.primary), lineWidth: 2)
                }

                if rect.width > 64, rect.height > 34 {
                    var clipped = context
                    clipped.clip(to: Path(rect.insetBy(dx: 4, dy: 3)))
                    let name = Text(item.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    let size = Text(formatBytes(item.sizeBytes)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.9))
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
        .animation(.snappy(duration: 0.18), value: checked)
    }
}
