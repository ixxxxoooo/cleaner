// 清理前安全复核：防止误删用户数据与系统目录
// @author ygw
import Foundation

/// 安全校验失败原因
public enum SafetyError: Error, Sendable, Equatable, LocalizedError {
    case displayOnly
    case outsideHome
    case protectedPath
    case whitelisted
    case containsGit
    case notFound
    case notDirectory
    case ruleMismatch
    case unknownRule

    public var errorDescription: String? {
        switch self {
        case .displayOnly: "该项仅供展示，不允许直接删除"
        case .outsideHome: "路径不在用户主目录内"
        case .protectedPath: "路径属于受保护目录"
        case .whitelisted: "路径位于白名单内"
        case .containsGit: "路径涉及 .git 目录"
        case .notFound: "路径已不存在"
        case .notDirectory: "路径不是真实目录（可能是符号链接）"
        case .ruleMismatch: "路径已不再符合识别规则，请重新扫描"
        case .unknownRule: "找不到对应的识别规则"
        }
    }
}

/// 安全守卫
public struct SafetyGuard: Sendable {
    private let homePath: String
    private let whitelist: [String]
    private let rules: [String: Rule]

    /// 主目录下禁止直接清理的一级目录
    private static let protectedTopLevel: Set<String> = [
        "Documents", "Desktop", "Downloads", "Library", "Pictures", "Movies", "Music", "Public", "Applications",
    ]

    /// 创建安全守卫
    /// - Parameters:
    ///   - homePath: 用户主目录
    ///   - whitelist: 白名单路径
    ///   - rules: 当前生效的规则
    public init(homePath: String = NSHomeDirectory(), whitelist: [String] = [], rules: [Rule] = RuleCatalog.builtin) {
        self.homePath = homePath
        self.whitelist = whitelist.map { ($0 as NSString).standardizingPath }
        self.rules = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// 校验一个结果项是否允许被清理
    /// - Parameter item: 扫描结果项
    /// - Returns: 通过返回 nil，否则返回失败原因
    public func validate(_ item: ScanItem) -> SafetyError? {
        if item.level == .displayOnly { return .displayOnly }
        let path = (item.path as NSString).standardizingPath
        guard path == item.path else { return .protectedPath }
        if path == homePath || path == "/" { return .protectedPath }
        guard path.hasPrefix(homePath + "/") else { return .outsideHome }
        let relative = String(path.dropFirst(homePath.count + 1))
        let components = relative.split(separator: "/").map(String.init)
        if components.isEmpty { return .protectedPath }
        if components.count == 1, Self.protectedTopLevel.contains(components[0]) { return .protectedPath }
        if components.contains(".git") { return .containsGit }
        for entry in whitelist where path == entry || path.hasPrefix(entry + "/") { return .whitelisted }

        switch DirectoryReader.lstatKind(path) {
        case .directory: break
        case .symlink: return .notDirectory
        default: return FileManager.default.fileExists(atPath: path) ? .notDirectory : .notFound
        }

        guard let rule = rules[item.ruleID] else { return .unknownRule }
        return matches(rule: rule, path: path, relative: relative) ? nil : .ruleMismatch
    }

    /// 复核路径是否仍符合规则（防止扫描后目录被替换）
    private func matches(rule: Rule, path: String, relative: String) -> Bool {
        switch rule.scope {
        case .global:
            for target in rule.targets {
                if relative == target { return true }
                if rule.expandChildren, (relative as NSString).deletingLastPathComponent == target { return true }
            }
            return false
        case .project:
            let name = (path as NSString).lastPathComponent
            guard rule.targets.contains(where: { NameMatcher.matches($0, name) }) else { return false }
            if rule.markers.isEmpty { return true }
            let parent = (path as NSString).deletingLastPathComponent
            guard let entries = DirectoryReader.entries(at: parent) else { return false }
            return CompiledRule(rule).matchedMarker(in: entries.map(\.name)) != nil
        }
    }
}
