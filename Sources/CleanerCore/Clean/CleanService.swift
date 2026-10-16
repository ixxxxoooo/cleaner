// 清理服务：移入废纸篓（可还原）或永久删除，并记录清理历史
// @author ygw
import Foundation

/// 清理历史记录
public struct CleanRecord: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var date: Date
    public var originalPath: String
    /// 废纸篓中的最终路径（永久删除时为 nil）
    public var trashedPath: String?
    public var sizeBytes: Int64
    public var mode: CleanMode
    public var title: String
    public var stack: TechStack
    /// 是否已被还原
    public var restored: Bool

    public init(
        id: UUID = UUID(), date: Date = Date(), originalPath: String, trashedPath: String?,
        sizeBytes: Int64, mode: CleanMode, title: String, stack: TechStack, restored: Bool = false
    ) {
        self.id = id
        self.date = date
        self.originalPath = originalPath
        self.trashedPath = trashedPath
        self.sizeBytes = sizeBytes
        self.mode = mode
        self.title = title
        self.stack = stack
        self.restored = restored
    }
}

/// 单项清理失败信息
public struct CleanFailure: Sendable, Identifiable {
    public var id: String { item.path }
    public let item: ScanItem
    public let message: String
}

/// 清理结果
public struct CleanOutcome: Sendable {
    public var records: [CleanRecord]
    public var failures: [CleanFailure]
    /// 成功清理的总字节数
    public var freedBytes: Int64 { records.reduce(0) { $0 + $1.sizeBytes } }
}

/// 清理服务
public struct CleanService: Sendable {
    private let guardRail: SafetyGuard

    /// 创建清理服务
    /// - Parameter guardRail: 安全守卫
    public init(guardRail: SafetyGuard) {
        self.guardRail = guardRail
    }

    /// 并发清理多个结果项
    /// - Parameters:
    ///   - items: 待清理项
    ///   - mode: 清理方式
    ///   - onProgress: 每完成一项回调（已完成数，总数）
    /// - Returns: 清理结果（成功记录与失败信息）
    public func clean(
        items: [ScanItem], mode: CleanMode, onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> CleanOutcome {
        let total = items.count
        var outcome = CleanOutcome(records: [], failures: [])
        var done = 0
        await withTaskGroup(of: (ScanItem, Result<CleanRecord, CleanErrorBox>).self) { group in
            for item in items {
                group.addTask {
                    (item, self.cleanOne(item, mode: mode))
                }
            }
            for await (item, result) in group {
                switch result {
                case .success(let record): outcome.records.append(record)
                case .failure(let error): outcome.failures.append(CleanFailure(item: item, message: error.message))
                }
                done += 1
                onProgress?(done, total)
            }
        }
        return outcome
    }

    /// 清理单个结果项（含安全复核）
    private func cleanOne(_ item: ScanItem, mode: CleanMode) -> Result<CleanRecord, CleanErrorBox> {
        if let error = guardRail.validate(item) {
            return .failure(CleanErrorBox(error.localizedDescription))
        }
        let url = URL(fileURLWithPath: item.path)
        do {
            var trashedPath: String?
            switch mode {
            case .trash:
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                trashedPath = (resulting as URL?)?.path
            case .permanent:
                try FileManager.default.removeItem(at: url)
            }
            return .success(CleanRecord(
                originalPath: item.path, trashedPath: trashedPath, sizeBytes: item.sizeBytes,
                mode: mode, title: item.title, stack: item.stack))
        } catch {
            return .failure(CleanErrorBox(error.localizedDescription))
        }
    }

    /// 还原一条已移入废纸篓的记录
    /// - Parameter record: 清理记录
    /// - Throws: 目标已存在或废纸篓项目不存在时抛出
    public static func restore(_ record: CleanRecord) throws {
        guard record.mode == .trash, let trashed = record.trashedPath else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "永久删除的项目无法还原"])
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: trashed) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "废纸篓中已找不到该项目（可能已被清空）"])
        }
        guard !fm.fileExists(atPath: record.originalPath) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "原位置已存在同名项目"])
        }
        try fm.moveItem(atPath: trashed, toPath: record.originalPath)
    }
}

/// 可跨并发域传递的错误信息盒
struct CleanErrorBox: Error, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}
