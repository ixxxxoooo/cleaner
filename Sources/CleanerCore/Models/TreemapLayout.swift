// 矩形树图布局：squarified 算法（纯计算，便于测试）
// @author ygw
import Foundation
import CoreGraphics

/// 树图布局输入项
public struct TreemapInput: Sendable {
    public let id: String
    public let value: Double
    public init(id: String, value: Double) {
        self.id = id
        self.value = value
    }
}

/// 树图布局输出
public struct TreemapCell: Sendable {
    public let id: String
    public let rect: CGRect
}

/// 树图布局器
public enum TreemapLayout {
    /// 计算布局
    /// - Parameters:
    ///   - inputs: 输入项（值需大于 0，内部会按值降序排列）
    ///   - bounds: 布局区域
    /// - Returns: 每个输入项对应的矩形，面积与值成正比
    public static func layout(_ inputs: [TreemapInput], in bounds: CGRect) -> [TreemapCell] {
        let items = inputs.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        let total = items.reduce(0) { $0 + $1.value }
        guard total > 0, bounds.width > 0, bounds.height > 0 else { return [] }
        let scale = Double(bounds.width * bounds.height) / total
        let areas = items.map { $0.value * scale }

        var cells = [TreemapCell]()
        cells.reserveCapacity(items.count)
        var rect = bounds
        var index = 0
        var row = [Int]()

        while index < items.count {
            let shortSide = Double(min(rect.width, rect.height))
            let candidate = row + [index]
            if row.isEmpty || worstRatio(candidate, areas, shortSide) <= worstRatio(row, areas, shortSide) {
                row = candidate
                index += 1
            } else {
                rect = place(row, items, areas, rect, &cells)
                row = []
            }
        }
        if !row.isEmpty { _ = place(row, items, areas, rect, &cells) }
        return cells
    }

    /// 计算一行的最差长宽比
    private static func worstRatio(_ row: [Int], _ areas: [Double], _ side: Double) -> Double {
        guard !row.isEmpty, side > 0 else { return .infinity }
        let sum = row.reduce(0) { $0 + areas[$1] }
        let maxArea = row.map { areas[$0] }.max() ?? 0
        let minArea = row.map { areas[$0] }.min() ?? 0
        let side2 = side * side
        return max(side2 * maxArea / (sum * sum), (sum * sum) / (side2 * max(minArea, 1e-9)))
    }

    /// 摆放一行并返回剩余区域
    private static func place(
        _ row: [Int], _ items: [TreemapInput], _ areas: [Double], _ rect: CGRect, _ cells: inout [TreemapCell]
    ) -> CGRect {
        let sum = row.reduce(0) { $0 + areas[$1] }
        if rect.width >= rect.height {
            // 沿左侧竖向摆放
            let rowWidth = CGFloat(sum / Double(rect.height))
            var y = rect.minY
            for i in row {
                let h = CGFloat(areas[i] / Double(rowWidth))
                cells.append(TreemapCell(id: items[i].id, rect: CGRect(x: rect.minX, y: y, width: rowWidth, height: h)))
                y += h
            }
            return CGRect(x: rect.minX + rowWidth, y: rect.minY, width: max(0, rect.width - rowWidth), height: rect.height)
        } else {
            // 沿顶部横向摆放
            let rowHeight = CGFloat(sum / Double(rect.width))
            var x = rect.minX
            for i in row {
                let w = CGFloat(areas[i] / Double(rowHeight))
                cells.append(TreemapCell(id: items[i].id, rect: CGRect(x: x, y: rect.minY, width: w, height: rowHeight)))
                x += w
            }
            return CGRect(x: rect.minX, y: rect.minY + rowHeight, width: rect.width, height: max(0, rect.height - rowHeight))
        }
    }
}
