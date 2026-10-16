// 底层目录读取：基于 opendir/readdir，直接使用 d_type，避免逐项 stat
// @author ygw
import Foundation
import Darwin

/// 目录条目类型
enum EntryKind: Sendable {
    case directory, file, symlink, other
}

/// 目录条目
struct DirEntry: Sendable {
    let name: String
    let kind: EntryKind
}

/// 目录读取器
enum DirectoryReader {
    /// 读取目录下的全部条目（不含 . 与 ..）
    /// - Parameter path: 目录绝对路径
    /// - Returns: 条目列表；无权限或目录不存在时返回 nil
    static func entries(at path: String) -> [DirEntry]? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        var result = [DirEntry]()
        result.reserveCapacity(32)
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { tuplePtr in
                tuplePtr.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            var kind: EntryKind
            switch Int32(entry.pointee.d_type) {
            case Int32(DT_DIR): kind = .directory
            case Int32(DT_REG): kind = .file
            case Int32(DT_LNK): kind = .symlink
            case Int32(DT_UNKNOWN):
                // 部分文件系统不提供 d_type，退化为 lstat
                kind = lstatKind(path + "/" + name)
            default: kind = .other
            }
            result.append(DirEntry(name: name, kind: kind))
        }
        return result
    }

    /// 使用 lstat 判断路径类型（不跟随符号链接）
    /// - Parameter path: 绝对路径
    /// - Returns: 条目类型；失败返回 .other
    static func lstatKind(_ path: String) -> EntryKind {
        var st = stat()
        guard lstat(path, &st) == 0 else { return .other }
        switch st.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .file
        case S_IFLNK: return .symlink
        default: return .other
        }
    }

    /// 判断路径是否为真实目录（不跟随符号链接）
    static func isRealDirectory(_ path: String) -> Bool { lstatKind(path) == .directory }

    /// 读取路径的修改时间
    /// - Parameter path: 绝对路径
    /// - Returns: 修改时间；失败返回 nil
    static func modificationDate(_ path: String) -> Date? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }
}
