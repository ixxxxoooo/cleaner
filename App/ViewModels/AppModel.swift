// 应用主状态：扫描、勾选、清理、历史、白名单、自定义规则、Git 优化
// @author ygw
import SwiftUI
import Observation
import CleanerCore

/// 侧边栏分区
enum SidebarSection: Hashable {
    case dashboard, projects, global, git, history
}

/// 扫描阶段
enum ScanPhase {
    case idle, scanning, finished
}

/// 按技术栈汇总
struct StackTotal: Identifiable {
    var id: TechStack { stack }
    let stack: TechStack
    let bytes: Int64
    let count: Int
}

/// 等级筛选
enum LevelFilter: String, CaseIterable, Identifiable {
    case all = "全部", recommended = "极力推荐", safe = "安全", caution = "需谨慎"
    var id: String { rawValue }

    /// 判断结果项是否通过筛选
    func accepts(_ item: ScanItem) -> Bool {
        switch self {
        case .all: true
        case .recommended: item.level == .recommended
        case .safe: item.level == .safe
        case .caution: item.level == .caution || item.level == .displayOnly
        }
    }
}

/// 待确认的清理请求
struct PendingClean: Identifiable {
    let id = UUID()
    let items: [ScanItem]
    let mode: CleanMode
    /// 确认阶段：永久删除需要二次确认
    var stage = 1

    var bytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }
    var networkCount: Int { items.filter(\.requiresNetwork).count }
    var cautionCount: Int { items.filter { $0.level == .caution }.count }
    var activeCount: Int { items.filter(\.isActiveProject).count }
}

/// 清理完成报告
struct CleanReport: Identifiable {
    let id = UUID()
    let outcome: CleanOutcome
    let mode: CleanMode
}

/// Git 仓库的分析状态
struct GitState {
    var analysis: GitAnalysis?
    var busy = false
    var log = ""
    var errorMessage: String?
}

@MainActor
@Observable
final class AppModel {
    // MARK: 界面状态
    var section: SidebarSection = .dashboard
    var searchText = ""
    var levelFilter: LevelFilter = .all
    var grouped = false
    var focusedID: String?
    var showInspector = true
    var errorMessage: String?

    // MARK: 扫描状态
    private(set) var items: [ScanItem] = []
    private(set) var gitRepos: [GitRepoInfo] = []
    private(set) var phase: ScanPhase = .idle
    private(set) var progress: ScanProgress?
    private(set) var summary: ScanSummary?
    private(set) var lastScanDate: Date?
    private(set) var scanStartedAt: Date?

    // MARK: 汇总（扫描批次刷新时重新计算）
    private(set) var totalBytes: Int64 = 0
    private(set) var recommendedBytes: Int64 = 0
    private(set) var stackTotals: [StackTotal] = []
    private(set) var freeBytes: Int64 = 0
    private(set) var diskTotalBytes: Int64 = 0

    // MARK: 勾选与清理
    var checked: Set<String> = []
    var cleanMode: CleanMode = .trash
    var pendingClean: PendingClean?
    var cleanReport: CleanReport?
    private(set) var cleaning = false
    private(set) var cleanProgress: (done: Int, total: Int)?

    // MARK: 持久化配置
    private(set) var history: [CleanRecord] = Stores.history.load() ?? []
    private(set) var whitelist: [String] = Stores.whitelist.load() ?? []
    private(set) var customRules: [Rule] = Stores.customRules.load() ?? []
    var dormantDays: Int = UserDefaults.standard.object(forKey: "dormantDays") as? Int ?? 90 {
        didSet { UserDefaults.standard.set(dormantDays, forKey: "dormantDays") }
    }

    // MARK: 权限
    private(set) var hasFullDiskAccess = true

    // MARK: Git
    var gitStates: [String: GitState] = [:]

    private var scanTask: Task<Void, Never>?
    private var pendingItems: [ScanItem] = []
    private var pendingGit: [GitRepoInfo] = []

    init() {
        if let snapshot = Stores.scanCache.load() {
            items = snapshot.items.filter { FileManager.default.fileExists(atPath: $0.path) }
                .sorted { $0.sizeBytes > $1.sizeBytes }
            lastScanDate = snapshot.date
            recompute()
        }
        refreshDisk()
        refreshPermission()
        applyLaunchArguments()
    }

    /// 读取启动参数（如 `-section projects -grouped 1`），便于调试与截图
    private func applyLaunchArguments() {
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: "section") {
        case "projects": section = .projects
        case "global": section = .global
        case "git": section = .git
        case "history": section = .history
        default: break
        }
        if defaults.bool(forKey: "grouped") { grouped = true }
        if defaults.bool(forKey: "selectRecommended") { selectRecommended() }
        if let first = items.first, defaults.bool(forKey: "focusFirst") { focusedID = first.id }
    }

    // MARK: - 派生数据

    /// 当前生效的规则（内置 + 自定义）
    var activeRules: [Rule] { RuleCatalog.builtin + customRules }

    /// 已勾选的结果项
    var checkedItems: [ScanItem] { items.filter { checked.contains($0.id) && $0.isCleanable } }

    /// 已勾选的总字节数
    var checkedBytes: Int64 { checkedItems.reduce(0) { $0 + $1.sizeBytes } }

    /// 获取当前焦点项
    var focusedItem: ScanItem? { items.first { $0.id == focusedID } }

    /// 按作用域/等级/搜索词筛选结果项
    /// - Parameter scope: 作用域，nil 表示全部
    /// - Returns: 按体积降序的结果
    func filtered(scope: RuleScope?) -> [ScanItem] {
        let keyword = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { item in
            if let scope, item.scope != scope { return false }
            guard levelFilter.accepts(item) else { return false }
            if keyword.isEmpty { return true }
            return item.title.lowercased().contains(keyword) || item.path.lowercased().contains(keyword)
                || item.stack.displayName.lowercased().contains(keyword)
        }
    }

    /// 重新计算汇总数据
    private func recompute() {
        var total: Int64 = 0
        var recommended: Int64 = 0
        var byStack = [TechStack: (Int64, Int)]()
        for item in items {
            total += item.sizeBytes
            if item.level == .recommended { recommended += item.sizeBytes }
            let old = byStack[item.stack] ?? (0, 0)
            byStack[item.stack] = (old.0 + item.sizeBytes, old.1 + 1)
        }
        totalBytes = total
        recommendedBytes = recommended
        stackTotals = byStack.map { StackTotal(stack: $0.key, bytes: $0.value.0, count: $0.value.1) }
            .sorted { $0.bytes > $1.bytes }
    }

    /// 刷新磁盘剩余空间
    func refreshDisk() {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) {
            freeBytes = values.volumeAvailableCapacityForImportantUsage ?? 0
            diskTotalBytes = Int64(values.volumeTotalCapacity ?? 0)
        }
    }

    /// 刷新完全磁盘访问权限状态
    func refreshPermission() {
        hasFullDiskAccess = SystemActions.hasFullDiskAccess()
    }

    // MARK: - 扫描

    /// 开始或取消扫描（工具栏主按钮）
    func toggleScan() {
        if phase == .scanning { cancelScan() } else { startScan() }
    }

    /// 开始扫描
    func startScan() {
        guard phase != .scanning else { return }
        scanTask = Task { await runScan() }
    }

    /// 取消扫描
    func cancelScan() {
        scanTask?.cancel()
    }

    /// 执行扫描：流式接收事件，每 100ms 批量刷新界面，避免高频刷新
    private func runScan() async {
        phase = .scanning
        scanStartedAt = Date()
        summary = nil
        progress = nil
        items = []
        gitRepos = []
        pendingItems = []
        pendingGit = []
        refreshPermission()
        refreshDisk()

        let options = ScanOptions(rules: activeRules, whitelist: whitelist, dormantDays: dormantDays)
        let stream = ScanEngine(options: options).scan()
        let flusher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                self?.flushPending()
            }
        }
        var cancelled = false
        for await event in stream {
            switch event {
            case .item(let item): pendingItems.append(item)
            case .gitRepo(let repo): pendingGit.append(repo)
            case .progress(let p): progress = p
            case .finished(let s):
                summary = s
                cancelled = s.wasCancelled
            }
        }
        if Task.isCancelled { cancelled = true }
        flusher.cancel()
        flushPending()
        checked = checked.intersection(Set(items.map(\.id)))
        phase = .finished
        if !cancelled {
            lastScanDate = Date()
            let snapshot = ScanSnapshot(date: Date(), items: items)
            Task.detached(priority: .utility) { Stores.scanCache.save(snapshot) }
        }
        refreshDisk()
    }

    /// 把缓冲区的结果合并进列表并刷新汇总
    private func flushPending() {
        guard !pendingItems.isEmpty || !pendingGit.isEmpty else { return }
        if !pendingItems.isEmpty {
            items.append(contentsOf: pendingItems)
            items.sort { $0.sizeBytes > $1.sizeBytes }
            pendingItems.removeAll(keepingCapacity: true)
            recompute()
        }
        if !pendingGit.isEmpty {
            gitRepos.append(contentsOf: pendingGit)
            gitRepos.sort { $0.gitBytes > $1.gitBytes }
            pendingGit.removeAll(keepingCapacity: true)
        }
    }

    // MARK: - 勾选

    /// 切换勾选状态
    func toggle(_ item: ScanItem) {
        guard item.isCleanable else { return }
        if checked.contains(item.id) { checked.remove(item.id) } else { checked.insert(item.id) }
    }

    /// 是否已勾选
    func isChecked(_ item: ScanItem) -> Bool { checked.contains(item.id) }

    /// 一键勾选所有「极力推荐」项
    func selectRecommended() {
        checked.formUnion(items.filter { $0.level == .recommended && $0.isCleanable }.map(\.id))
    }

    /// 勾选给定列表中的全部可清理项
    func select(_ list: [ScanItem]) {
        checked.formUnion(list.filter(\.isCleanable).map(\.id))
    }

    /// 取消全部勾选
    func clearSelection() { checked.removeAll() }

    // MARK: - 清理

    /// 发起清理（弹出确认）
    func requestClean() {
        let list = checkedItems
        guard !list.isEmpty, !cleaning else { return }
        pendingClean = PendingClean(items: list, mode: cleanMode)
    }

    /// 确认清理：永久删除需要经过第二次确认
    func confirmClean() {
        guard var pending = pendingClean else { return }
        if pending.mode == .permanent, pending.stage == 1 {
            pending.stage = 2
            pendingClean = pending
            return
        }
        pendingClean = nil
        Task { await performClean(items: pending.items, mode: pending.mode) }
    }

    /// 取消清理请求
    func cancelClean() { pendingClean = nil }

    /// 执行清理并更新列表、历史与统计
    private func performClean(items target: [ScanItem], mode: CleanMode) async {
        cleaning = true
        cleanProgress = (0, target.count)
        let service = CleanService(guardRail: SafetyGuard(whitelist: whitelist, rules: activeRules))
        let outcome = await service.clean(items: target, mode: mode) { [weak self] done, total in
            Task { @MainActor in self?.cleanProgress = (done, total) }
        }
        let removed = Set(outcome.records.map(\.originalPath))
        items.removeAll { removed.contains($0.path) }
        checked.subtract(removed)
        if focusedID.map(removed.contains) == true { focusedID = nil }
        recompute()
        if !outcome.records.isEmpty {
            history.insert(contentsOf: outcome.records.sorted { $0.sizeBytes > $1.sizeBytes }, at: 0)
            if history.count > 500 { history = Array(history.prefix(500)) }
            Stores.history.save(history)
            let snapshot = ScanSnapshot(date: lastScanDate ?? Date(), items: items)
            Task.detached(priority: .utility) { Stores.scanCache.save(snapshot) }
        }
        cleaning = false
        cleanProgress = nil
        cleanReport = CleanReport(outcome: outcome, mode: mode)
        refreshDisk()
    }

    /// 还原一条历史记录
    /// - Parameter record: 清理记录
    func restore(_ record: CleanRecord) {
        do {
            try CleanService.restore(record)
            if let index = history.firstIndex(where: { $0.id == record.id }) {
                history[index].restored = true
                Stores.history.save(history)
            }
            refreshDisk()
            startScan()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 清空清理历史（不影响废纸篓中的文件）
    func clearHistory() {
        history.removeAll()
        Stores.history.save(history)
    }

    // MARK: - 白名单

    /// 添加白名单路径，并立即从当前结果中移除相关项
    func addToWhitelist(_ path: String) {
        let standardized = (path as NSString).standardizingPath
        guard !whitelist.contains(standardized) else { return }
        whitelist.append(standardized)
        Stores.whitelist.save(whitelist)
        items.removeAll { $0.path == standardized || $0.path.hasPrefix(standardized + "/") }
        checked = checked.intersection(Set(items.map(\.id)))
        recompute()
    }

    /// 把结果项所在项目（或自身路径）加入白名单
    func whitelist(item: ScanItem) {
        addToWhitelist(item.scope == .project ? (item.projectPath ?? item.path) : item.path)
    }

    /// 移除白名单路径
    func removeWhitelist(_ path: String) {
        whitelist.removeAll { $0 == path }
        Stores.whitelist.save(whitelist)
    }

    // MARK: - 自定义规则

    /// 从 JSON 文件导入自定义规则
    /// - Parameter url: JSON 文件（Rule 数组）
    func importRules(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let rules = try JSONDecoder().decode([Rule].self, from: data)
            let builtinIDs = Set(RuleCatalog.builtin.map(\.id))
            for rule in rules {
                if builtinIDs.contains(rule.id) { throw RuleError.message("规则 id「\(rule.id)」与内置规则冲突") }
                if let problem = Self.validate(rule) { throw RuleError.message("规则「\(rule.id)」：\(problem)") }
            }
            var merged = customRules.filter { old in !rules.contains { $0.id == old.id } }
            merged.append(contentsOf: rules)
            customRules = merged
            Stores.customRules.save(customRules)
        } catch let RuleError.message(text) {
            errorMessage = "导入失败：\(text)"
        } catch {
            errorMessage = "导入失败：\(error.localizedDescription)"
        }
    }

    /// 删除一条自定义规则
    func removeCustomRule(_ id: String) {
        customRules.removeAll { $0.id == id }
        Stores.customRules.save(customRules)
    }

    private enum RuleError: Error { case message(String) }

    /// 校验自定义规则的合法性（防止通过规则触碰任意路径）
    /// - Returns: 问题描述；合法返回 nil
    static func validate(_ rule: Rule) -> String? {
        if rule.id.trimmingCharacters(in: .whitespaces).isEmpty { return "id 不能为空" }
        if rule.targets.isEmpty { return "targets 不能为空" }
        if rule.level == .recommended { return "自定义规则的 level 不能是 recommended（该等级由休眠判定自动产生）" }
        for target in rule.targets {
            if target.isEmpty || target.contains("..") || target.hasPrefix("/") { return "目标路径「\(target)」不合法" }
            if rule.scope == .project, target.contains("/") { return "项目级目标只能是目录名：\(target)" }
            if rule.scope == .project, target == "*" { return "目标不能是通配符 *" }
        }
        return nil
    }

    // MARK: - Git 优化

    /// 分析仓库对象库
    func analyzeGit(_ repo: GitRepoInfo) {
        var state = gitStates[repo.path] ?? GitState()
        guard !state.busy else { return }
        state.busy = true
        state.errorMessage = nil
        gitStates[repo.path] = state
        Task {
            var next = gitStates[repo.path] ?? GitState()
            do { next.analysis = try await GitAnalyzer.analyze(repoPath: repo.path) } catch { next.errorMessage = error.localizedDescription }
            next.busy = false
            gitStates[repo.path] = next
        }
    }

    /// 执行 git gc
    func gcGit(_ repo: GitRepoInfo, aggressive: Bool) {
        runGit(repo) { path in try await GitAnalyzer.gc(repoPath: path, aggressive: aggressive) }
    }

    /// 清理失效的 worktree 记录
    func pruneWorktrees(_ repo: GitRepoInfo) {
        runGit(repo) { path in try await GitAnalyzer.pruneWorktrees(repoPath: path) }
    }

    /// 执行 Git 维护操作，完成后刷新体积与分析
    private func runGit(_ repo: GitRepoInfo, operation: @escaping @Sendable (String) async throws -> String) {
        var state = gitStates[repo.path] ?? GitState()
        guard !state.busy else { return }
        state.busy = true
        state.errorMessage = nil
        state.log = "执行中…"
        gitStates[repo.path] = state
        Task {
            var next = gitStates[repo.path] ?? GitState()
            do {
                next.log = try await operation(repo.path)
                next.analysis = try? await GitAnalyzer.analyze(repoPath: repo.path)
                let total = await SizeCalculator.size(of: repo.path + "/.git")
                let objects = await SizeCalculator.size(of: repo.path + "/.git/objects")
                if let index = gitRepos.firstIndex(where: { $0.path == repo.path }) {
                    let before = gitRepos[index].gitBytes
                    gitRepos[index].gitBytes = total.bytes
                    gitRepos[index].objectsBytes = objects.bytes
                    next.log += "\n.git 体积：\(formatBytes(before)) → \(formatBytes(total.bytes))"
                }
            } catch {
                next.errorMessage = error.localizedDescription
                next.log = ""
            }
            next.busy = false
            gitStates[repo.path] = next
            refreshDisk()
        }
    }
}
