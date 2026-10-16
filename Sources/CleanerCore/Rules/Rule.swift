// 数据驱动规则：特征文件 + 目标目录 的联动映射
// @author ygw
import Foundation

/// 单条识别规则（可 JSON 序列化，供 Phase 3 自定义规则复用）
public struct Rule: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    /// 展示名，如「Node 依赖」
    public var name: String
    public var stack: TechStack
    public var scope: RuleScope
    /// 项目级：特征文件（任一存在即命中，支持 `*.ext` 后缀通配）；为空表示仅按目录名匹配
    public var markers: [String]
    /// 项目级：目标目录名模式（支持前缀/后缀 `*`）；全局级：相对用户主目录的路径
    public var targets: [String]
    public var level: CleanLevel
    /// 全局级：是否把目标目录下的每个子目录拆成独立结果项（如 DerivedData）
    public var expandChildren: Bool
    public var requiresNetwork: Bool
    /// 清理影响说明
    public var regenNote: String
    /// 仅展示项的操作引导命令
    public var guide: String?

    public init(
        id: String, name: String, stack: TechStack, scope: RuleScope = .project,
        markers: [String] = [], targets: [String], level: CleanLevel,
        expandChildren: Bool = false, requiresNetwork: Bool = false,
        regenNote: String, guide: String? = nil
    ) {
        self.id = id
        self.name = name
        self.stack = stack
        self.scope = scope
        self.markers = markers
        self.targets = targets
        self.level = level
        self.expandChildren = expandChildren
        self.requiresNetwork = requiresNetwork
        self.regenNote = regenNote
        self.guide = guide
    }
}

/// 名称匹配工具：支持 `prefix*`、`*suffix` 与精确匹配
public enum NameMatcher {
    /// 判断名称是否匹配模式
    /// - Parameters:
    ///   - pattern: 模式，可带一个首/尾 `*`
    ///   - name: 待匹配名称
    /// - Returns: 是否匹配
    public static func matches(_ pattern: String, _ name: String) -> Bool {
        if pattern.hasPrefix("*") { return name.hasSuffix(String(pattern.dropFirst())) }
        if pattern.hasSuffix("*") { return name.hasPrefix(String(pattern.dropLast())) }
        return pattern == name
    }

    /// 模式是否含通配符
    public static func isWildcard(_ pattern: String) -> Bool {
        pattern.hasPrefix("*") || pattern.hasSuffix("*")
    }
}

/// 预编译规则：加速特征文件检查
struct CompiledRule: Sendable {
    let rule: Rule
    let exactMarkers: Set<String>
    let suffixMarkers: [String]

    init(_ rule: Rule) {
        self.rule = rule
        var exact = Set<String>()
        var suffix = [String]()
        for marker in rule.markers {
            if marker.hasPrefix("*") { suffix.append(String(marker.dropFirst())) } else { exact.insert(marker) }
        }
        exactMarkers = exact
        suffixMarkers = suffix
    }

    /// 检查目录条目中是否存在特征文件
    /// - Parameter entryNames: 目录下所有条目名称
    /// - Returns: 命中的特征文件名（无特征要求时返回空串），未命中返回 nil
    func matchedMarker(in entryNames: [String]) -> String? {
        if rule.markers.isEmpty { return "" }
        for name in entryNames {
            if exactMarkers.contains(name) { return name }
            for suffix in suffixMarkers where name.hasSuffix(suffix) { return name }
        }
        return nil
    }
}

extension Rule {
    /// 宽松解码：自定义规则 JSON 只需提供必要字段，其余使用默认值
    /// - Parameter decoder: 解码器
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let scope = try c.decodeIfPresent(RuleScope.self, forKey: .scope) ?? .project
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? c.decode(String.self, forKey: .id),
            stack: try c.decodeIfPresent(TechStack.self, forKey: .stack) ?? .other,
            scope: scope,
            markers: try c.decodeIfPresent([String].self, forKey: .markers) ?? [],
            targets: try c.decode([String].self, forKey: .targets),
            level: try c.decodeIfPresent(CleanLevel.self, forKey: .level) ?? .caution,
            expandChildren: try c.decodeIfPresent(Bool.self, forKey: .expandChildren) ?? false,
            requiresNetwork: try c.decodeIfPresent(Bool.self, forKey: .requiresNetwork) ?? false,
            regenNote: try c.decodeIfPresent(String.self, forKey: .regenNote) ?? "清理后相关工具会按需重新生成",
            guide: try c.decodeIfPresent(String.self, forKey: .guide))
    }
}
