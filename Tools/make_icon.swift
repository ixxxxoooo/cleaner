// 生成应用图标：深色渐变圆角方块 + 彩色环形图（磁盘占用）+ 中心闪光（清理）
// 用法：swift Tools/make_icon.swift  → 输出 App/Assets.xcassets/AppIcon.appiconset
// @author ygw
import AppKit

/// 把颜色字符串转成 NSColor
/// - Parameter hex: 如 0x34C759
/// - Returns: NSColor
func color(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// 绘制 1024x1024 图标
/// - Returns: 位图
func drawIcon() -> NSBitmapImageRep {
    let size = 1024
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // 图标主体：824 圆角方块，四周留白给系统阴影
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

    // 外阴影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    color(0x0B1530).setFill()
    bodyPath.fill()
    ctx.restoreGState()

    // 背景渐变（深蓝 → 靛蓝）
    ctx.saveGState()
    bodyPath.addClip()
    let bg = NSGradient(colors: [color(0x1B2B5E), color(0x0A1128)])!
    bg.draw(in: body, angle: -70)
    // 左上高光
    let glow = NSGradient(colors: [color(0x5AA9FF, 0.35), color(0x5AA9FF, 0)])!
    glow.draw(fromCenter: CGPoint(x: 300, y: 820), radius: 0, toCenter: CGPoint(x: 300, y: 820), radius: 520, options: [])
    ctx.restoreGState()

    // 环形图：各技术栈配色，段与段之间留缝
    let center = CGPoint(x: 512, y: 512)
    let outer: CGFloat = 300, inner: CGFloat = 178
    let segments: [(Double, Int)] = [(0.31, 0x34C759), (0.26, 0x32D4E8), (0.20, 0x0A84FF), (0.13, 0xFFD60A), (0.10, 0xFF9F0A)]
    var start: CGFloat = 90  // 从 12 点方向开始，顺时针
    let gap: CGFloat = 3.2
    for (fraction, hex) in segments {
        let sweep = CGFloat(fraction) * 360
        let a0 = start - gap / 2, a1 = start - sweep + gap / 2
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: outer, startAngle: a0, endAngle: a1, clockwise: true)
        path.appendArc(withCenter: center, radius: inner, startAngle: a1, endAngle: a0, clockwise: false)
        path.close()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        color(hex).setFill()
        path.fill()
        ctx.restoreGState()
        // 段内顶部高光
        ctx.saveGState()
        path.addClip()
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.30), NSColor.white.withAlphaComponent(0)])!
            .draw(in: path.bounds, angle: -90)
        ctx.restoreGState()
        start -= sweep
    }

    // 中心玻璃圆盘
    let disc = NSBezierPath(ovalIn: CGRect(x: center.x - 150, y: center.y - 150, width: 300, height: 300))
    ctx.saveGState()
    disc.addClip()
    NSGradient(colors: [color(0x2D4A94, 0.95), color(0x0E1A3F, 0.95)])!.draw(in: disc.bounds, angle: -90)
    ctx.restoreGState()
    NSColor.white.withAlphaComponent(0.28).setStroke()
    disc.lineWidth = 4
    disc.stroke()

    // 中心四角闪光（代表“清理干净”）
    func sparkle(at c: CGPoint, r: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        let k = r * 0.22
        p.move(to: CGPoint(x: c.x, y: c.y + r))
        p.curve(to: CGPoint(x: c.x + r, y: c.y), controlPoint1: CGPoint(x: c.x + k, y: c.y + k), controlPoint2: CGPoint(x: c.x + k, y: c.y + k))
        p.curve(to: CGPoint(x: c.x, y: c.y - r), controlPoint1: CGPoint(x: c.x + k, y: c.y - k), controlPoint2: CGPoint(x: c.x + k, y: c.y - k))
        p.curve(to: CGPoint(x: c.x - r, y: c.y), controlPoint1: CGPoint(x: c.x - k, y: c.y - k), controlPoint2: CGPoint(x: c.x - k, y: c.y - k))
        p.curve(to: CGPoint(x: c.x, y: c.y + r), controlPoint1: CGPoint(x: c.x - k, y: c.y + k), controlPoint2: CGPoint(x: c.x - k, y: c.y + k))
        p.close()
        return p
    }
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30, color: color(0x7FD0FF, 0.9).cgColor)
    NSColor.white.setFill()
    sparkle(at: CGPoint(x: 502, y: 502), r: 108).fill()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 16, color: color(0x7FD0FF, 0.9).cgColor)
    NSColor.white.setFill()
    sparkle(at: CGPoint(x: 575, y: 585), r: 34).fill()
    ctx.restoreGState()

    // 主体内描边高光
    NSColor.white.withAlphaComponent(0.14).setStroke()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: 184, yRadius: 184)
    rim.lineWidth = 4
    rim.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// 将位图缩放写成指定像素尺寸的 PNG
/// - Parameters:
///   - rep: 1024 原图
///   - pixels: 目标像素
///   - url: 输出路径
func writePNG(_ rep: NSBitmapImageRep, pixels: Int, to url: URL) {
    let out = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    NSGraphicsContext.current?.imageInterpolation = .high
    rep.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try! out.representation(using: .png, properties: [:])!.write(to: url)
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "App/Assets.xcassets")
let set = root.appendingPathComponent("AppIcon.appiconset")
try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
let master = drawIcon()
var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        writePNG(master, pixels: base * scale, to: set.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: set.appendingPathComponent("Contents.json"))
try! JSONSerialization.data(withJSONObject: ["info": ["version": 1, "author": "xcode"]])
    .write(to: root.appendingPathComponent("Contents.json"))
writePNG(master, pixels: 1024, to: URL(fileURLWithPath: "/tmp/icon_preview.png"))
print("图标已生成")
