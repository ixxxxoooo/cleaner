// 核心数据模型：技术栈、清理等级、规则作用域、扫描结果项
// @author ygw
import Foundation

/// 技术栈分类，用于标签、配色与分组
public enum TechStack: String, Codable, CaseIterable, Sendable {
    case node, rust, java, android, xcode, swift, python, dotnet, cpp, go, dart, php
    case homebrew, docker, git, other

    /// 展示名称
    public var displayName: String {
        switch self {
        case .node: "Node / 前端"
        case .rust: "Rust"
        case .java: "Java / Gradle"
        case .android: "Android"
        case .xcode: "Xcode"
        case .swift: "Swift"
        case .python: "Python"
        case .dotnet: ".NET"
        case .cpp: "C / C++"
        case .go: "Go"
        case .dart: "Flutter / Dart"
        case .php: "PHP"
        case .homebrew: "Homebrew"
        case .docker: "Docker"
        case .git: "Git"
        case .other: "其他"
        }
    }
}

/// 清理建议等级（数值越小越推荐清理）
public enum CleanLevel: Int, Codable, CaseIterable, Sendable, Comparable {
    /// 极力推荐：休眠项目的构建产物
    case recommended = 0
    /// 安全：纯编译中间件/缓存，可本地自动再生
    case safe = 1
    /// 需谨慎：全局依赖仓或可能被版本控制的产物，清理后需重新下载/确认
    case caution = 2
    /// 仅展示：不提供直接删除，只给出引导
    case displayOnly = 3

    public static func < (lhs: CleanLevel, rhs: CleanLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    /// 展示名称
    public var title: String {
        switch self {
        case .recommended: "极力推荐"
        case .safe: "安全"
        case .caution: "需谨慎"
        case .displayOnly: "仅展示"
        }
    }
}

/// 规则作用域：项目级（由特征文件触发）或全局级（固定路径）
public enum RuleScope: String, Codable, Sendable {
    case project
    case global
}

/// 单条扫描结果
public struct ScanItem: Codable, Sendable, Identifiable, Hashable {
    /// 以绝对路径作为唯一标识
    public var id: String { path }
    public var path: String
    /// 列表展示名（项目级为「项目 / 目录」，全局级为规则名或子目录名）
    public var title: String
    public var scope: RuleScope
    public var ruleID: String
    public var ruleName: String
    public var stack: TechStack
    public var level: CleanLevel
    /// 实际占用字节数（按分配块计算，硬链接已去重）
    public var sizeBytes: Int64
    public var fileCount: Int
    /// 最近一次源码活动时间（项目级）或目录修改时间
    public var lastActivity: Date?
    /// 所属项目目录（项目级）或关联工程目录
    public var projectPath: String?
    /// 是否为休眠项目（源码超过阈值未改动）
    public var isDormant: Bool
    /// 是否为近期活跃项目（默认不勾选）
    public var isActiveProject: Bool
    /// 命中原因（特征文件说明）
    public var reason: String
    /// 清理后的影响说明
    public var regenNote: String
    public var requiresNetwork: Bool
    /// 仅展示项的操作引导
    public var guide: String?

    public init(
        path: String, title: String, scope: RuleScope, ruleID: String, ruleName: String, stack: TechStack,
        level: CleanLevel, sizeBytes: Int64, fileCount: Int, lastActivity: Date?,
        projectPath: String?, isDormant: Bool, isActiveProject: Bool, reason: String,
        regenNote: String, requiresNetwork: Bool, guide: String?
    ) {
        self.path = path
        self.title = title
        self.scope = scope
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.stack = stack
        self.level = level
        self.sizeBytes = sizeBytes
        self.fileCount = fileCount
        self.lastActivity = lastActivity
        self.projectPath = projectPath
        self.isDormant = isDormant
        self.isActiveProject = isActiveProject
        self.reason = reason
        self.regenNote = regenNote
        self.requiresNetwork = requiresNetwork
        self.guide = guide
    }

    /// 目录名
    public var name: String { (path as NSString).lastPathComponent }

    /// 所属项目名（无则返回空串）
    public var projectName: String {
        guard let projectPath else { return "" }
        return (projectPath as NSString).lastPathComponent
    }

    /// 是否允许清理（仅展示项不允许）
    public var isCleanable: Bool { level != .displayOnly }
}

/// 扫描进度
public struct ScanProgress: Sendable, Equatable {
    /// 已访问目录数
    public var visitedDirectories: Int
    /// 已发现结果数
    public var foundItems: Int
    /// 因权限等原因跳过的目录数
    public var skippedDirectories: Int
}

/// 扫描汇总
public struct ScanSummary: Sendable, Equatable {
    public var totalItems: Int
    public var totalBytes: Int64
    public var visitedDirectories: Int
    public var skippedDirectories: Int
    public var duration: TimeInterval
    public var wasCancelled: Bool
}

/// 扫描过程事件（流式输出）
public enum ScanEvent: Sendable {
    /// 发现并计算完成一个结果项
    case item(ScanItem)
    /// 发现一个 .git 体积异常膨胀的仓库
    case gitRepo(GitRepoInfo)
    /// 进度更新（节流）
    case progress(ScanProgress)
    /// 扫描结束
    case finished(ScanSummary)
}

/// 清理方式
public enum CleanMode: String, Codable, Sendable {
    /// 移入废纸篓（可还原，空间在清空废纸篓后释放）
    case trash
    /// 立即永久删除（不可恢复）
    case permanent
}
