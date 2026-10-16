// 项目活跃度探测：读取源码文件最后修改时间，命中近期修改即早退
// @author ygw
import Foundation
import Darwin

/// 活跃度探测器
public enum ActivityProbe {
    /// 视为源码的文件扩展名
    static let sourceExtensions: Set<String> = [
        "rs", "java", "kt", "kts", "scala", "groovy", "ts", "tsx", "js", "jsx", "mjs", "cjs", "vue", "svelte",
        "py", "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cs", "fs", "go", "dart", "php", "rb",
        "html", "css", "scss", "md", "json", "toml", "yaml", "yml", "gradle", "xml", "sh",
    ]

    /// 探测时跳过的目录名（构建产物、依赖、版本库）
    static let skipDirectories: Set<String> = [
        "node_modules", "target", "build", "dist", "out", "bin", "obj", "Pods", "vendor", "venv",
        "__pycache__", "DerivedData", "Carthage", "coverage",
    ]

    /// 单次探测最多访问的条目数，防止巨型目录拖慢扫描
    static let maxVisited = 30_000

    /// 获取项目最近一次源码修改时间
    /// - Parameters:
    ///   - projectPath: 项目根目录绝对路径
    ///   - recentThreshold: 近期阈值时间；一旦发现不早于该时间的源码文件立即返回
    /// - Returns: 最近的源码修改时间；找不到任何源码返回 nil
    public static func latestSourceActivity(projectPath: String, recentThreshold: Date) -> Date? {
        let threshold = recentThreshold.timeIntervalSince1970
        var newest: TimeInterval = 0
        var visited = 0
        var stack = [projectPath]

        while let dir = stack.popLast() {
            guard let entries = DirectoryReader.entries(at: dir) else { continue }
            for entry in entries {
                visited += 1
                if visited > maxVisited { return newest > 0 ? Date(timeIntervalSince1970: newest) : nil }
                switch entry.kind {
                case .directory:
                    if entry.name.hasPrefix(".") || skipDirectories.contains(entry.name) { continue }
                    stack.append(dir + "/" + entry.name)
                case .file:
                    let ext = (entry.name as NSString).pathExtension.lowercased()
                    guard sourceExtensions.contains(ext) else { continue }
                    var st = stat()
                    guard lstat(dir + "/" + entry.name, &st) == 0 else { continue }
                    let mtime = TimeInterval(st.st_mtimespec.tv_sec)
                    if mtime > newest { newest = mtime }
                    // 早退：已确认近期活跃
                    if newest >= threshold { return Date(timeIntervalSince1970: newest) }
                default:
                    continue
                }
            }
        }
        return newest > 0 ? Date(timeIntervalSince1970: newest) : nil
    }
}
