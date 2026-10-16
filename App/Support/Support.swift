// 界面辅助：格式化、技术栈配色、等级配色、系统交互
// @author ygw
import SwiftUI
import AppKit
import CleanerCore

/// 字节数格式化
/// - Parameter bytes: 字节数
/// - Returns: 如「1.2 GB」
func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

extension TechStack {
    /// 技术栈配色（全部使用系统语义色，自动适配明暗模式与 Liquid Glass）
    var color: Color {
        switch self {
        case .node: .green
        case .rust: .orange
        case .java: .red
        case .android: .mint
        case .xcode: .blue
        case .swift: .cyan
        case .python: .yellow
        case .dotnet: .purple
        case .cpp: .indigo
        case .go: .teal
        case .dart: .blue
        case .php: .pink
        case .homebrew: .brown
        case .docker: .cyan
        case .git: .orange
        case .other: .gray
        }
    }
}

extension CleanLevel {
    /// 等级配色
    var color: Color {
        switch self {
        case .recommended: .green
        case .safe: .blue
        case .caution: .orange
        case .displayOnly: .gray
        }
    }

    /// 等级图标
    var symbol: String {
        switch self {
        case .recommended: "sparkles"
        case .safe: "checkmark.shield"
        case .caution: "exclamationmark.triangle"
        case .displayOnly: "eye"
        }
    }
}

extension ScanItem {
    /// 闲置天数（无活动记录返回 nil）
    var idleDays: Int? {
        guard let lastActivity else { return nil }
        return max(0, Int(Date().timeIntervalSince(lastActivity) / 86_400))
    }

    /// 排序用的闲置天数（未知排最后）
    var idleSortKey: Int { idleDays ?? -1 }

    /// 闲置时间的人类可读描述
    var idleText: String {
        guard let days = idleDays else { return "—" }
        if days < 1 { return "今天" }
        if days < 30 { return "\(days) 天" }
        if days < 365 { return "\(days / 30) 个月" }
        return String(format: "%.1f 年", Double(days) / 365)
    }

    /// 带 ~ 缩写的路径
    var shortPath: String { (path as NSString).abbreviatingWithTildeInPath }
}

/// 系统交互工具
@MainActor
enum SystemActions {
    /// 在 Finder 中显示
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// 复制文本到剪贴板
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 打开废纸篓
    static func openTrash() {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
    }

    /// 通过 Finder 清空废纸篓（首次会弹出自动化授权）
    /// - Returns: 失败时的错误信息
    static func emptyTrash() -> String? {
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\" to empty the trash")?.executeAndReturnError(&error)
        return error?[NSAppleScript.errorMessage] as? String
    }

    /// 打开系统设置的「完全磁盘访问权限」页面
    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 重新启动本应用（授权完全磁盘访问后需重启才生效）
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.6; /usr/bin/open -n \"\(path)\""]
        try? process.run()
        NSApp.terminate(nil)
    }

    /// 检测是否已具备完全磁盘访问权限：探测多个受 TCC 保护的目录
    /// - Returns: 任一目录可读返回 true；全部被拒绝返回 false；所有目录都不存在时无法判断，按已授权处理
    nonisolated static func hasFullDiskAccess() -> Bool {
        let home = NSHomeDirectory()
        let probes = [
            "Library/Application Support/com.apple.TCC", "Library/Mail", "Library/Messages",
            "Library/Safari", "Library/Containers/com.apple.stocks",
        ]
        var denied = false
        for relative in probes {
            if let dir = opendir(home + "/" + relative) {
                closedir(dir)
                return true
            }
            if errno == EPERM || errno == EACCES { denied = true }
        }
        return !denied
    }
}
