// Git 仓库专项：识别体积膨胀的 .git，分析对象库，提示 gc / prune 而非删除仓库
// @author ygw
import Foundation

/// 扫描阶段发现的 Git 仓库概要（体积超过阈值才会上报）
public struct GitRepoInfo: Codable, Sendable, Identifiable, Hashable {
    public var id: String { path }
    /// 仓库工作目录
    public var path: String
    /// .git 目录总占用
    public var gitBytes: Int64
    /// .git/objects 占用
    public var objectsBytes: Int64

    public init(path: String, gitBytes: Int64, objectsBytes: Int64) {
        self.path = path
        self.gitBytes = gitBytes
        self.objectsBytes = objectsBytes
    }

    /// 仓库名
    public var name: String { (path as NSString).lastPathComponent }
}

/// 对仓库的深度分析结果
public struct GitAnalysis: Sendable, Equatable {
    /// 松散对象数量
    public var looseObjects: Int
    /// 松散对象占用字节
    public var looseBytes: Int64
    /// 打包文件数
    public var packs: Int
    /// 打包文件占用字节
    public var packBytes: Int64
    /// 垃圾文件占用字节
    public var garbageBytes: Int64
    /// 可 prune 的废弃 worktree 路径
    public var prunableWorktrees: [String]
    /// 是否建议执行 git gc
    public var shouldGC: Bool {
        looseObjects > 5_000 || looseBytes > 50 * 1_048_576 || packs > 20 || garbageBytes > 0
    }
}

/// Git 操作错误
public struct GitError: Error, Sendable, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// Git 分析与优化
public enum GitAnalyzer {
    /// 判定为「体积异常」并上报的 .git 体积阈值（100 MB）
    public static let reportThreshold: Int64 = 100 * 1_048_576

    /// 分析仓库对象库与废弃 worktree
    /// - Parameter repoPath: 仓库工作目录
    /// - Returns: 分析结果
    /// - Throws: git 执行失败时抛出
    public static func analyze(repoPath: String) async throws -> GitAnalysis {
        let counts = try await run(["count-objects", "-v"], in: repoPath)
        var values = [String: Int64]()
        for line in counts.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, let number = Int64(parts[1]) { values[parts[0]] = number }
        }
        var prunable = [String]()
        if let list = try? await run(["worktree", "list", "--porcelain"], in: repoPath) {
            var currentPath: String?
            for line in list.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("worktree ") { currentPath = String(line.dropFirst("worktree ".count)) }
                if line.hasPrefix("prunable"), let currentPath { prunable.append(currentPath) }
            }
        }
        return GitAnalysis(
            looseObjects: Int(values["count"] ?? 0), looseBytes: (values["size"] ?? 0) * 1024,
            packs: Int(values["packs"] ?? 0), packBytes: (values["size-pack"] ?? 0) * 1024,
            garbageBytes: (values["size-garbage"] ?? 0) * 1024, prunableWorktrees: prunable)
    }

    /// 执行 git gc 优化对象库
    /// - Parameters:
    ///   - repoPath: 仓库工作目录
    ///   - aggressive: 是否使用 --aggressive（更慢、压缩更狠）
    /// - Returns: git 输出
    public static func gc(repoPath: String, aggressive: Bool = false) async throws -> String {
        try await run(aggressive ? ["gc", "--aggressive", "--prune=now"] : ["gc", "--prune=now"], in: repoPath)
    }

    /// 清理已失效的 worktree 记录
    public static func pruneWorktrees(repoPath: String) async throws -> String {
        try await run(["worktree", "prune", "-v"], in: repoPath)
    }

    /// 在指定目录执行 git 命令
    private static func run(_ arguments: [String], in directory: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.terminationHandler = { proc in
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                let outText = String(data: outData, encoding: .utf8) ?? ""
                let errText = String(data: errData, encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: outText + errText)
                } else {
                    continuation.resume(throwing: GitError(message: errText.isEmpty ? outText : errText))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: GitError(message: error.localizedDescription)) }
        }
    }
}
