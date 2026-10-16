// 并发扫描引擎：剪枝遍历 + 流式输出 + 取消
// @author ygw
import Foundation
import Darwin
import Synchronization

/// 扫描上下文（并发共享，全部成员线程安全）
final class ScanContext: Sendable {
    let options: ScanOptions
    /// 目录名 → 候选规则（按规则优先级排序）
    let exactTargets: [String: [CompiledRule]]
    /// 含通配目标的规则
    let wildcardRules: [CompiledRule]
    let globalRules: [Rule]
    let whitelist: Set<String>
    /// 全局规则的绝对路径（遍历时跳过，避免重复扫描）
    let globalPaths: Set<String>
    let threshold: Date
    let continuation: AsyncStream<ScanEvent>.Continuation

    let visited = Atomic<Int>(0)
    let skipped = Atomic<Int>(0)
    let found = Atomic<Int>(0)
    let totalBytes = Atomic<Int64>(0)
    private let activityCache = Mutex<[String: ActivityCacheEntry]>([:])
    private let emittedPaths = Mutex<Set<String>>([])

    struct ActivityCacheEntry: Sendable { let date: Date? }

    init(options: ScanOptions, continuation: AsyncStream<ScanEvent>.Continuation) {
        self.options = options
        self.continuation = continuation
        let projectRules = options.rules.filter { $0.scope == .project }.map(CompiledRule.init)
        var exact = [String: [CompiledRule]]()
        var wildcard = [CompiledRule]()
        for compiled in projectRules {
            var hasWildcard = false
            for target in compiled.rule.targets {
                if NameMatcher.isWildcard(target) { hasWildcard = true } else { exact[target, default: []].append(compiled) }
            }
            if hasWildcard { wildcard.append(compiled) }
        }
        exactTargets = exact
        wildcardRules = wildcard
        let globals = options.rules.filter { $0.scope == .global }
        globalRules = globals
        whitelist = Set(options.whitelist.map { ($0 as NSString).standardizingPath })
        globalPaths = Set(globals.flatMap { $0.targets.map { options.homePath + "/" + $0 } })
        threshold = Date().addingTimeInterval(-Double(options.dormantDays) * 86_400)
    }

    /// 判断路径是否在白名单内（路径本身或其上级被列入白名单）
    func isWhitelisted(_ path: String) -> Bool {
        if whitelist.isEmpty { return false }
        var current = path
        while current.count > 1 {
            if whitelist.contains(current) { return true }
            current = (current as NSString).deletingLastPathComponent
        }
        return false
    }

    /// 获取项目活跃度（带缓存，同一项目的多个构建目录只探测一次）
    func activity(forProject path: String) -> Date? {
        if let cached = activityCache.withLock({ $0[path] }) { return cached.date }
        let date = ActivityProbe.latestSourceActivity(projectPath: path, recentThreshold: threshold)
        activityCache.withLock { $0[path] = ActivityCacheEntry(date: date) }
        return date
    }

    /// 发出结果项（同一路径只发一次）并更新统计
    func emit(_ item: ScanItem) {
        let isNew = emittedPaths.withLock { $0.insert(item.path).inserted }
        guard isNew else { return }
        found.add(1, ordering: .relaxed)
        totalBytes.add(item.sizeBytes, ordering: .relaxed)
        continuation.yield(.item(item))
    }

    /// 发出进度事件
    func emitProgress() {
        continuation.yield(.progress(ScanProgress(
            visitedDirectories: visited.load(ordering: .relaxed),
            foundItems: found.load(ordering: .relaxed),
            skippedDirectories: skipped.load(ordering: .relaxed))))
    }
}

/// 扫描引擎
public final class ScanEngine: Sendable {
    private let options: ScanOptions

    /// 创建扫描引擎
    /// - Parameter options: 扫描配置
    public init(options: ScanOptions = ScanOptions()) {
        self.options = options
    }

    /// 开始扫描
    /// - Returns: 事件流；流被取消或丢弃时扫描任务自动取消
    public func scan() -> AsyncStream<ScanEvent> {
        let options = self.options
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task(priority: options.priority) {
                let ctx = ScanContext(options: options, continuation: continuation)
                let start = ContinuousClock.now
                await Self.run(ctx)
                let elapsed = ContinuousClock.now - start
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                continuation.yield(.finished(ScanSummary(
                    totalItems: ctx.found.load(ordering: .relaxed),
                    totalBytes: ctx.totalBytes.load(ordering: .relaxed),
                    visitedDirectories: ctx.visited.load(ordering: .relaxed),
                    skippedDirectories: ctx.skipped.load(ordering: .relaxed),
                    duration: seconds,
                    wasCancelled: Task.isCancelled)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 并发执行：项目级目录遍历与全局级固定路径同时进行
    private static func run(_ ctx: ScanContext) async {
        await withTaskGroup(of: Void.self) { group in
            for root in ctx.options.roots {
                group.addTask { await walk(path: (root as NSString).standardizingPath, depth: 0, ctx: ctx) }
            }
            if ctx.options.includeGlobal {
                for rule in ctx.globalRules {
                    group.addTask { await processGlobal(rule: rule, ctx: ctx) }
                }
            }
        }
    }

    // MARK: - 项目级遍历

    /// 主目录下默认跳过的一级目录（体积大且不含开发项目）
    private static let homeSkip: Set<String> = ["Library", "Pictures", "Movies", "Music", "Applications", ".Trash"]
    /// 默认跳过的包目录后缀
    private static let bundleSuffixes = [".app", ".photoslibrary", ".imovielibrary", ".fcpbundle",
                                         ".musiclibrary", ".tvlibrary", ".sparsebundle", ".xcarchive"]

    /// 判断是否应下钻到子目录
    private static func shouldDescend(name: String, path: String, parent: String, depth: Int, ctx: ScanContext) -> Bool {
        if name.hasPrefix(".") { return false }
        if depth + 1 > ctx.options.maxDepth { return false }
        if parent == ctx.options.homePath, homeSkip.contains(name) { return false }
        for suffix in bundleSuffixes where name.hasSuffix(suffix) { return false }
        if ctx.globalPaths.contains(path) { return false }
        if ctx.isWhitelisted(path) { return false }
        return true
    }

    /// 遍历目录：命中则计算体积并停止下钻，未命中则并发进入子目录
    /// - Parameters:
    ///   - path: 目录绝对路径
    ///   - depth: 当前深度
    ///   - ctx: 扫描上下文
    private static func walk(path: String, depth: Int, ctx: ScanContext) async {
        if Task.isCancelled { return }
        guard let entries = DirectoryReader.entries(at: path) else {
            ctx.skipped.add(1, ordering: .relaxed)
            return
        }
        let count = ctx.visited.add(1, ordering: .relaxed).newValue
        if count % 2048 == 0 { ctx.emitProgress() }

        var hits: [(rule: CompiledRule, dirName: String, marker: String)] = []
        var descend: [String] = []
        var entryNames: [String]?

        for entry in entries where entry.kind == .directory {
            var candidates = ctx.exactTargets[entry.name] ?? []
            for compiled in ctx.wildcardRules
            where compiled.rule.targets.contains(where: { NameMatcher.isWildcard($0) && NameMatcher.matches($0, entry.name) }) {
                candidates.append(compiled)
            }
            var matched = false
            if !candidates.isEmpty {
                let names = entryNames ?? entries.map(\.name)
                entryNames = names
                for compiled in candidates {
                    if let marker = compiled.matchedMarker(in: names) {
                        hits.append((compiled, entry.name, marker))
                        matched = true
                        break
                    }
                }
            }
            if matched { continue }
            let childPath = path + "/" + entry.name
            if shouldDescend(name: entry.name, path: childPath, parent: path, depth: depth, ctx: ctx) {
                descend.append(childPath)
            }
        }

        let hasGit = ctx.options.includeGit && entries.contains { $0.name == ".git" && $0.kind == .directory }
        await withTaskGroup(of: Void.self) { group in
            if hasGit {
                group.addTask { await processGit(repoPath: path, ctx: ctx) }
            }
            for hit in hits {
                group.addTask { await processProjectHit(rule: hit.rule.rule, dirName: hit.dirName, marker: hit.marker, parent: path, ctx: ctx) }
            }
            for child in descend {
                group.addTask { await walk(path: child, depth: depth + 1, ctx: ctx) }
            }
        }
    }

    /// 处理项目级命中：计算体积与活跃度并输出结果
    private static func processProjectHit(
        rule: Rule, dirName: String, marker: String, parent: String, ctx: ScanContext
    ) async {
        let target = parent + "/" + dirName
        if Task.isCancelled || ctx.isWhitelisted(target) { return }
        async let sizeResult = SizeCalculator.size(of: target)
        let lastActivity = ctx.activity(forProject: parent)
        let size = await sizeResult
        if size.bytes <= 0 || Task.isCancelled { return }

        var level = rule.level
        var dormant = false
        var active = false
        if let lastActivity {
            dormant = lastActivity < ctx.threshold
            active = !dormant
        }
        if dormant, level == .safe { level = .recommended }

        let projectName = (parent as NSString).lastPathComponent
        let reason = marker.isEmpty ? "目录名匹配 \(dirName)" : "检测到 \(marker)，对应构建目录 \(dirName)"
        ctx.emit(ScanItem(
            path: target, title: "\(projectName) / \(dirName)", scope: .project, ruleID: rule.id,
            ruleName: rule.name, stack: rule.stack, level: level, sizeBytes: size.bytes,
            fileCount: size.files, lastActivity: lastActivity, projectPath: parent, isDormant: dormant,
            isActiveProject: active, reason: reason, regenNote: rule.regenNote,
            requiresNetwork: rule.requiresNetwork, guide: rule.guide))
    }

    /// 计算 .git 体积，超过阈值则上报（提示 git gc 而非删除）
    private static func processGit(repoPath: String, ctx: ScanContext) async {
        if Task.isCancelled || ctx.isWhitelisted(repoPath) { return }
        let git = repoPath + "/.git"
        async let objects = SizeCalculator.size(of: git + "/objects")
        let total = await SizeCalculator.size(of: git)
        let objectsSize = await objects
        guard total.bytes >= GitAnalyzer.reportThreshold, !Task.isCancelled else { return }
        ctx.continuation.yield(.gitRepo(GitRepoInfo(path: repoPath, gitBytes: total.bytes, objectsBytes: objectsSize.bytes)))
    }

    // MARK: - 全局级处理

    /// 处理全局规则：检查固定路径是否存在，必要时拆分子目录
    private static func processGlobal(rule: Rule, ctx: ScanContext) async {
        await withTaskGroup(of: Void.self) { group in
            for target in rule.targets {
                let absolute = ctx.options.homePath + "/" + target
                if Task.isCancelled || ctx.isWhitelisted(absolute) { continue }
                guard DirectoryReader.isRealDirectory(absolute) else { continue }
                if rule.expandChildren {
                    guard let children = DirectoryReader.entries(at: absolute) else {
                        ctx.skipped.add(1, ordering: .relaxed)
                        continue
                    }
                    for child in children where child.kind == .directory {
                        let childPath = absolute + "/" + child.name
                        if ctx.isWhitelisted(childPath) { continue }
                        group.addTask { await processGlobalItem(rule: rule, path: childPath, title: nil, expanded: true, ctx: ctx) }
                    }
                } else {
                    let title = rule.targets.count > 1 ? "\(rule.name) · ~/\(target)" : rule.name
                    group.addTask { await processGlobalItem(rule: rule, path: absolute, title: title, expanded: false, ctx: ctx) }
                }
            }
        }
    }

    /// 计算并输出一个全局结果项
    private static func processGlobalItem(
        rule: Rule, path: String, title: String?, expanded: Bool, ctx: ScanContext
    ) async {
        async let sizeResult = SizeCalculator.size(of: path)
        var title = title ?? (path as NSString).lastPathComponent
        var projectPath: String?
        var lastActivity: Date?
        var dormant = false
        var active = false
        var reason = "固定路径 ~/" + String(path.dropFirst(ctx.options.homePath.count + 1))

        if expanded {
            lastActivity = DirectoryReader.modificationDate(path)
            if rule.id == "g-xcode-derived", let workspace = derivedDataWorkspace(path) {
                let name = ((workspace as NSString).lastPathComponent as NSString).deletingPathExtension
                title = "\(name) · DerivedData"
                let project = (workspace as NSString).deletingLastPathComponent
                projectPath = project
                if FileManager.default.fileExists(atPath: workspace) {
                    if let date = ctx.activity(forProject: project) { lastActivity = date }
                } else {
                    dormant = true
                    reason = "原工程已不存在：\(workspace)"
                }
            }
            if let lastActivity, !dormant {
                dormant = lastActivity < ctx.threshold
                active = !dormant && projectPath != nil
            }
        }
        let size = await sizeResult
        if size.bytes <= 0 || Task.isCancelled { return }

        var level = rule.level
        if dormant, level == .safe { level = .recommended }
        ctx.emit(ScanItem(
            path: path, title: title, scope: .global, ruleID: rule.id, ruleName: rule.name,
            stack: rule.stack, level: level, sizeBytes: size.bytes, fileCount: size.files,
            lastActivity: lastActivity, projectPath: projectPath, isDormant: dormant,
            isActiveProject: active, reason: reason, regenNote: rule.regenNote,
            requiresNetwork: rule.requiresNetwork, guide: rule.guide))
    }

    /// 读取 DerivedData 子目录 Info.plist 中记录的工程路径
    private static func derivedDataWorkspace(_ derivedPath: String) -> String? {
        let plistURL = URL(fileURLWithPath: derivedPath + "/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let workspace = plist["WorkspacePath"] as? String else { return nil }
        return workspace
    }
}
