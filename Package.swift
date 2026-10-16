// swift-tools-version: 6.2
// 开发者磁盘清理 App 的核心库与命令行工具
// @author ygw
import PackageDescription

let package = Package(
    name: "CleanerCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "CleanerCore", targets: ["CleanerCore"]),
        .executable(name: "cleaner-scan", targets: ["cleaner-scan"]),
    ],
    targets: [
        // 扫描、规则、体积计算、清理服务（不依赖 UI）
        .target(name: "CleanerCore"),
        // 不开 UI 的命令行扫描工具，用于调试与性能基准
        .executableTarget(name: "cleaner-scan", dependencies: ["CleanerCore"]),
        .testTarget(name: "CleanerCoreTests", dependencies: ["CleanerCore"]),
    ]
)
