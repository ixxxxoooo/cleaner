// 体积计算：getattrlistbulk 批量读取实际占用块大小，硬链接去重，前两层目录并行
// @author ygw
import Foundation
import Darwin
import Synchronization

/// 体积计算结果
public struct SizeResult: Sendable, Equatable {
    /// 实际占用字节（分配块大小，硬链接只计一次）
    public var bytes: Int64
    /// 文件数量
    public var files: Int
}

/// 硬链接键（设备号 + inode）
private struct InodeKey: Hashable, Sendable {
    let dev: UInt32
    let ino: UInt64
}

/// 硬链接去重器（单个结果项范围内共享）
private final class HardlinkTracker: Sendable {
    private let seen = Mutex<Set<InodeKey>>([])

    /// 登记一个硬链接文件
    /// - Returns: 首次出现返回 true（应计入体积），重复出现返回 false
    func firstSeen(dev: UInt32, ino: UInt64) -> Bool {
        seen.withLock { $0.insert(InodeKey(dev: dev, ino: ino)).inserted }
    }
}

/// 单层目录扫描结果
private struct LevelResult {
    var bytes: Int64 = 0
    var files: Int = 0
    var subdirs: [String] = []
}

/// 体积计算器
public enum SizeCalculator {
    // getattrlist 属性位（直接使用数值，避免宏导入类型差异）
    private static let cmnName: UInt32 = 0x0000_0001
    private static let cmnDevID: UInt32 = 0x0000_0002
    private static let cmnObjType: UInt32 = 0x0000_0008
    private static let cmnFileID: UInt32 = 0x0200_0000
    private static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    private static let fileLinkCount: UInt32 = 0x0000_0001
    private static let fileAllocSize: UInt32 = 0x0000_0004
    private static let vDir: UInt32 = 2
    private static let bufferSize = 256 * 1024
    /// 并行展开的目录层数（再往下顺序遍历，避免任务爆炸）
    private static let parallelDepth = 2

    /// 计算目录（或文件）的实际占用大小
    /// - Parameter path: 绝对路径
    /// - Returns: 体积结果；路径不存在时为 0
    public static func size(of path: String) async -> SizeResult {
        var st = stat()
        guard lstat(path, &st) == 0 else { return SizeResult(bytes: 0, files: 0) }
        if (st.st_mode & S_IFMT) != S_IFDIR {
            return SizeResult(bytes: Int64(st.st_blocks) * 512, files: 1)
        }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return SizeResult(bytes: 0, files: 0) }
        defer { close(fd) }
        let tracker = HardlinkTracker()
        return await parallelSize(fd: fd, depth: 0, tracker: tracker)
    }

    /// 并行展开前几层目录并汇总
    private static func parallelSize(fd: Int32, depth: Int, tracker: HardlinkTracker) async -> SizeResult {
        if Task.isCancelled { return SizeResult(bytes: 0, files: 0) }
        let level = scanLevel(fd: fd, tracker: tracker)
        var total = SizeResult(bytes: level.bytes, files: level.files)
        if level.subdirs.isEmpty { return total }

        if depth >= parallelDepth || level.subdirs.count < 2 && depth > 0 {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
            defer { buffer.deallocate() }
            for name in level.subdirs {
                let part = sequentialSize(parentFD: fd, name: name, tracker: tracker, buffer: buffer)
                total.bytes += part.bytes
                total.files += part.files
            }
            return total
        }

        await withTaskGroup(of: SizeResult.self) { group in
            for name in level.subdirs {
                group.addTask {
                    let childFD = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                    guard childFD >= 0 else { return SizeResult(bytes: 0, files: 0) }
                    defer { close(childFD) }
                    return await parallelSize(fd: childFD, depth: depth + 1, tracker: tracker)
                }
            }
            for await part in group {
                total.bytes += part.bytes
                total.files += part.files
            }
        }
        return total
    }

    /// 顺序递归计算子目录体积
    private static func sequentialSize(
        parentFD: Int32, name: String, tracker: HardlinkTracker, buffer: UnsafeMutableRawPointer
    ) -> SizeResult {
        if Task.isCancelled { return SizeResult(bytes: 0, files: 0) }
        let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return SizeResult(bytes: 0, files: 0) }
        defer { close(fd) }
        let level = scanLevel(fd: fd, tracker: tracker, buffer: buffer)
        var total = SizeResult(bytes: level.bytes, files: level.files)
        for sub in level.subdirs {
            let part = sequentialSize(parentFD: fd, name: sub, tracker: tracker, buffer: buffer)
            total.bytes += part.bytes
            total.files += part.files
        }
        return total
    }

    /// 扫描单层目录（自行分配缓冲区）
    private static func scanLevel(fd: Int32, tracker: HardlinkTracker) -> LevelResult {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }
        return scanLevel(fd: fd, tracker: tracker, buffer: buffer)
    }

    /// 扫描单层目录：批量读取条目，累加文件占用并收集子目录名
    /// - Parameters:
    ///   - fd: 目录文件描述符
    ///   - tracker: 硬链接去重器
    ///   - buffer: 复用的属性缓冲区
    /// - Returns: 本层文件体积、文件数与子目录名
    private static func scanLevel(
        fd: Int32, tracker: HardlinkTracker, buffer: UnsafeMutableRawPointer
    ) -> LevelResult {
        var result = LevelResult()
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = cmnReturnedAttrs | cmnName | cmnDevID | cmnObjType | cmnFileID
        list.fileattr = fileLinkCount | fileAllocSize

        while true {
            let count = getattrlistbulk(fd, &list, buffer, bufferSize, 0)
            if count <= 0 { break }
            var cursor = UnsafeRawPointer(buffer)
            for _ in 0..<Int(count) {
                let entryStart = cursor
                let length = Int(cursor.loadUnaligned(as: UInt32.self))
                var field = cursor + 4
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size

                var name: String?
                var dev: UInt32 = 0
                var objType: UInt32 = 0
                var fileID: UInt64 = 0
                var linkCount: UInt32 = 1
                var allocSize: Int64 = 0

                if returned.commonattr & cmnName != 0 {
                    let ref = field.loadUnaligned(as: attrreference_t.self)
                    let namePtr = (field + Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
                    name = String(cString: namePtr)
                    field += MemoryLayout<attrreference_t>.size
                }
                if returned.commonattr & cmnDevID != 0 {
                    dev = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                if returned.commonattr & cmnObjType != 0 {
                    objType = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                if returned.commonattr & cmnFileID != 0 {
                    fileID = field.loadUnaligned(as: UInt64.self)
                    field += 8
                }
                if returned.fileattr & fileLinkCount != 0 {
                    linkCount = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                if returned.fileattr & fileAllocSize != 0 {
                    allocSize = field.loadUnaligned(as: Int64.self)
                    field += 8
                }

                if objType == vDir {
                    if let name { result.subdirs.append(name) }
                } else {
                    // 硬链接文件仅首次计入
                    if linkCount > 1, !tracker.firstSeen(dev: dev, ino: fileID) {
                        // 已计入，跳过
                    } else {
                        result.bytes += allocSize
                    }
                    result.files += 1
                }
                cursor = entryStart + length
            }
        }
        return result
    }
}
