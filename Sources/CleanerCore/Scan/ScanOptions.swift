// 扫描配置
// @author ygw
import Foundation

/// 扫描配置
public struct ScanOptions: Sendable {
    /// 用户主目录绝对路径（全局规则的基准）
    public var homePath: String
    /// 扫描根目录列表，默认仅主目录
    public var roots: [String]
    /// 生效的规则（内置 + 自定义）
    public var rules: [Rule]
    /// 白名单路径（该路径及其子路径不扫描、不清理）
    public var whitelist: [String]
    /// 是否扫描全局级缓存
    public var includeGlobal: Bool
    /// 休眠判定天数（源码超过该天数未改动即视为休眠项目）
    public var dormantDays: Int
    /// 最大遍历深度
    public var maxDepth: Int
    /// 是否检测体积膨胀的 Git 仓库
    public var includeGit: Bool

    public init(
        homePath: String = NSHomeDirectory(), roots: [String]? = nil, rules: [Rule] = RuleCatalog.builtin,
        whitelist: [String] = [], includeGlobal: Bool = true, dormantDays: Int = 90, maxDepth: Int = 14,
        includeGit: Bool = true
    ) {
        self.homePath = homePath
        self.roots = roots ?? [homePath]
        self.rules = rules
        self.whitelist = whitelist
        self.includeGlobal = includeGlobal
        self.dormantDays = dormantDays
        self.maxDepth = maxDepth
        self.includeGit = includeGit
    }
}
