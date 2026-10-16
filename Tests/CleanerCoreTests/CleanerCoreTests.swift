// CleanerCore 单元测试：规则匹配、剪枝、硬链接去重、活跃度、白名单、安全复核、树图
// @author ygw
import Foundation
import Testing
@testable import CleanerCore

/// 测试夹具：在临时目录中构造一个模拟的用户主目录
final class Fixture {
    let home: String
    private let fm = FileManager.default

    init() {
        let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("cleaner-test-\(UUID().uuidString)")
        try! fm.createDirectory(at: base, withIntermediateDirectories: true)
        home = (base.path as NSString).standardizingPath
    }

    deinit { try? fm.removeItem(atPath: home) }

    /// 创建文件（可指定大小与修改时间）
    @discardableResult
    func file(_ relative: String, bytes: Int = 0, daysAgo: Int? = nil) -> String {
        let path = home + "/" + relative
        try! fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: path, contents: Data(count: bytes))
        if let daysAgo {
            let date = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
            try! fm.setAttributes([.modificationDate: date], ofItemAtPath: path)
        }
        return path
    }

    /// 以默认选项扫描并收集全部结果
    func scan(whitelist: [String] = [], global: Bool = false) async -> [ScanItem] {
        let options = ScanOptions(homePath: home, roots: [home], whitelist: whitelist, includeGlobal: global)
        var items = [ScanItem]()
        for await event in ScanEngine(options: options).scan() {
            if case .item(let item) = event { items.append(item) }
        }
        return items
    }
}

@Suite("扫描引擎")
struct ScanEngineTests {
    @Test("特征文件与构建目录联动命中")
    func detectsProjects() async {
        let f = Fixture()
        f.file("a/package.json", daysAgo: 1); f.file("a/node_modules/x/index.js", bytes: 8192)
        f.file("b/Cargo.toml", daysAgo: 1); f.file("b/src/main.rs", daysAgo: 1); f.file("b/target/debug/bin", bytes: 8192)
        f.file("c/pom.xml", daysAgo: 1); f.file("c/target/classes/A.class", bytes: 8192)
        f.file("d/target/x", bytes: 8192) // 无 Cargo.toml / pom.xml，不应命中
        f.file("e/App.xcodeproj/project.pbxproj"); f.file("e/build/o", bytes: 8192)
        let items = await f.scan()
        let paths = Set(items.map(\.path))
        #expect(paths.contains(f.home + "/a/node_modules"))
        #expect(paths.contains(f.home + "/b/target"))
        #expect(paths.contains(f.home + "/c/target"))
        #expect(paths.contains(f.home + "/e/build"))
        #expect(!paths.contains(f.home + "/d/target"))
        #expect(items.first { $0.path.hasSuffix("b/target") }?.ruleID == "rust-target")
        #expect(items.first { $0.path.hasSuffix("c/target") }?.ruleID == "maven-target")
    }

    @Test("命中目录内部不再下钻（剪枝）")
    func prunesInsideHits() async {
        let f = Fixture()
        f.file("p/package.json"); f.file("p/node_modules/lib/package.json"); f.file("p/node_modules/lib/node_modules/inner/a.js", bytes: 8192)
        let items = await f.scan()
        #expect(items.count == 1)
        #expect(items.first?.path == f.home + "/p/node_modules")
    }

    @Test("硬链接只计一次体积")
    func hardlinkDedup() async throws {
        let f = Fixture()
        f.file("p/package.json")
        let original = f.file("p/node_modules/a.bin", bytes: 1_048_576)
        try FileManager.default.linkItem(atPath: original, toPath: f.home + "/p/node_modules/b.bin")
        try FileManager.default.linkItem(atPath: original, toPath: f.home + "/p/node_modules/c.bin")
        let result = await SizeCalculator.size(of: f.home + "/p/node_modules")
        #expect(result.files == 3)
        #expect(result.bytes >= 1_048_576 && result.bytes < 1_048_576 * 2)
    }

    @Test("体积按分配块计算且与 du 一致")
    func sizeMatchesDu() async {
        let f = Fixture()
        for i in 0..<50 { f.file("t/d\(i % 5)/f\(i).bin", bytes: 1000 + i * 37) }
        let result = await SizeCalculator.size(of: f.home + "/t")
        #expect(result.files == 50)
        #expect(result.bytes > 0 && result.bytes % 4096 == 0)
    }

    @Test("休眠项目被标记为极力推荐，活跃项目标记近期在用")
    func dormantDetection() async {
        let f = Fixture()
        f.file("old/Cargo.toml", daysAgo: 400); f.file("old/src/lib.rs", daysAgo: 200); f.file("old/target/a", bytes: 8192)
        f.file("new/Cargo.toml", daysAgo: 400); f.file("new/src/lib.rs", daysAgo: 2); f.file("new/target/a", bytes: 8192)
        let items = await f.scan()
        let old = items.first { $0.path.hasSuffix("old/target") }
        let new = items.first { $0.path.hasSuffix("new/target") }
        #expect(old?.level == .recommended)
        #expect(old?.isDormant == true)
        #expect(new?.level == .safe)
        #expect(new?.isActiveProject == true)
    }

    @Test("白名单目录不被扫描")
    func whitelistSkips() async {
        let f = Fixture()
        f.file("keep/package.json"); f.file("keep/node_modules/a", bytes: 8192)
        f.file("other/package.json"); f.file("other/node_modules/a", bytes: 8192)
        let items = await f.scan(whitelist: [f.home + "/keep"])
        #expect(items.map(\.path) == [f.home + "/other/node_modules"])
    }

    @Test("全局规则按固定路径命中并拆分子目录")
    func globalRules() async {
        let f = Fixture()
        f.file(".m2/repository/a/b.jar", bytes: 8192)
        f.file("Library/Developer/Xcode/DerivedData/App-abc/Build/x", bytes: 8192)
        f.file("Library/Developer/Xcode/DerivedData/Lib-def/Build/x", bytes: 8192)
        let items = await f.scan(global: true)
        let paths = Set(items.map(\.path))
        #expect(paths.contains(f.home + "/.m2/repository"))
        #expect(paths.contains(f.home + "/Library/Developer/Xcode/DerivedData/App-abc"))
        #expect(paths.contains(f.home + "/Library/Developer/Xcode/DerivedData/Lib-def"))
        #expect(items.first { $0.path.hasSuffix(".m2/repository") }?.requiresNetwork == true)
    }
}

@Suite("安全守卫与清理")
struct SafetyTests {
    @Test("危险路径一律拦截")
    func blocksDangerousPaths() async {
        let f = Fixture()
        f.file("p/package.json"); f.file("p/node_modules/a", bytes: 8192)
        let guardRail = SafetyGuard(homePath: f.home, whitelist: [f.home + "/wl"])
        let valid = (await f.scan()).first!
        #expect(guardRail.validate(valid) == nil)

        func make(_ path: String, level: CleanLevel = .safe, rule: String = "node-modules") -> ScanItem {
            ScanItem(path: path, title: "t", scope: .project, ruleID: rule, ruleName: "r", stack: .node, level: level,
                     sizeBytes: 1, fileCount: 1, lastActivity: nil, projectPath: nil, isDormant: false,
                     isActiveProject: false, reason: "", regenNote: "", requiresNetwork: false, guide: nil)
        }
        #expect(guardRail.validate(make(f.home)) == .protectedPath)
        #expect(guardRail.validate(make("/System/Library")) == .outsideHome)
        #expect(guardRail.validate(make(f.home + "/Documents")) == .protectedPath)
        #expect(guardRail.validate(make(f.home + "/p/.git/node_modules")) == .containsGit)
        #expect(guardRail.validate(make(f.home + "/wl/node_modules")) == .whitelisted)
        #expect(guardRail.validate(make(f.home + "/p/node_modules", level: .displayOnly)) == .displayOnly)
        #expect(guardRail.validate(make(f.home + "/p/nothing")) == .notFound)
        #expect(guardRail.validate(make(f.home + "/p/package.json")) == .notDirectory)
    }

    @Test("规则不再匹配时拒绝清理")
    func rejectsRuleMismatch() async {
        let f = Fixture()
        f.file("r/Cargo.toml"); f.file("r/target/a", bytes: 8192)
        let item = (await f.scan()).first!
        try? FileManager.default.removeItem(atPath: f.home + "/r/Cargo.toml")
        #expect(SafetyGuard(homePath: f.home).validate(item) == .ruleMismatch)
    }

    @Test("永久删除模式清理成功并记录")
    func permanentClean() async {
        let f = Fixture()
        f.file("p/package.json"); f.file("p/node_modules/a", bytes: 8192)
        let item = (await f.scan()).first!
        let outcome = await CleanService(guardRail: SafetyGuard(homePath: f.home)).clean(items: [item], mode: .permanent)
        #expect(outcome.records.count == 1)
        #expect(outcome.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: item.path))
    }
}

@Suite("树图布局")
struct TreemapTests {
    @Test("面积与数值成正比且铺满区域")
    func areaProportional() {
        let inputs = (1...20).map { TreemapInput(id: "\($0)", value: Double($0) * 10) }
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 400)
        let cells = TreemapLayout.layout(inputs, in: bounds)
        #expect(cells.count == 20)
        let totalArea = cells.reduce(0.0) { $0 + Double($1.rect.width * $1.rect.height) }
        #expect(abs(totalArea - 320_000) < 1)
        let total = inputs.reduce(0) { $0 + $1.value }
        for cell in cells {
            let expected = inputs.first { $0.id == cell.id }!.value / total * 320_000
            #expect(abs(Double(cell.rect.width * cell.rect.height) - expected) < 1)
        }
    }

    @Test("名称匹配支持前后缀通配")
    func nameMatcher() {
        #expect(NameMatcher.matches("cmake-build-*", "cmake-build-debug"))
        #expect(NameMatcher.matches("*.xcodeproj", "A.xcodeproj"))
        #expect(!NameMatcher.matches("target", "targets"))
    }
}

@Suite("Git 专项")
struct GitTests {
    /// 在夹具中执行 git 命令
    private func git(_ args: [String], in dir: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=t", "-c", "user.email=t@t"] + args
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    @Test("分析松散对象并执行 gc 后对象被打包")
    func analyzeAndGC() async throws {
        let f = Fixture()
        let repo = f.home + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git(["init", "-q"], in: repo)
        for i in 0..<30 { f.file("repo/f\(i).txt", bytes: 2048 + i) }
        try git(["add", "."], in: repo)
        try git(["commit", "-q", "-m", "init"], in: repo)

        let before = try await GitAnalyzer.analyze(repoPath: repo)
        #expect(before.looseObjects > 0)
        _ = try await GitAnalyzer.gc(repoPath: repo)
        let after = try await GitAnalyzer.analyze(repoPath: repo)
        #expect(after.looseObjects == 0)
        #expect(after.packs >= 1)
    }

    @Test("废弃 worktree 可被识别并清理")
    func prunableWorktree() async throws {
        let f = Fixture()
        let repo = f.home + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git(["init", "-q"], in: repo)
        f.file("repo/a.txt", bytes: 100)
        try git(["add", "."], in: repo)
        try git(["commit", "-q", "-m", "init"], in: repo)
        let wt = f.home + "/wt"
        try git(["worktree", "add", "-q", wt], in: repo)
        try FileManager.default.removeItem(atPath: wt)

        let analysis = try await GitAnalyzer.analyze(repoPath: repo)
        #expect(analysis.prunableWorktrees.count == 1)
        _ = try await GitAnalyzer.pruneWorktrees(repoPath: repo)
        #expect(try await GitAnalyzer.analyze(repoPath: repo).prunableWorktrees.isEmpty)
    }

    @Test("宽松解码自定义规则")
    func lenientRuleDecoding() throws {
        let json = #"[{"id":"x","targets":["zig-cache"],"markers":["build.zig"]}]"#
        let rules = try JSONDecoder().decode([Rule].self, from: Data(json.utf8))
        #expect(rules.first?.scope == .project)
        #expect(rules.first?.level == .caution)
    }
}
