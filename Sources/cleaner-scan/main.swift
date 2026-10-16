// 命令行扫描工具：用于调试与性能基准
// 用法：cleaner-scan [--root 路径]... [--top N] [--no-global] [--dormant-days N] [--verify] [--json]
// @author ygw
import Foundation
import CleanerCore

/// 命令行参数
struct Arguments {
    var roots: [String] = []
    var top = 30
    var includeGlobal = true
    var dormantDays = 90
    var verify = false
    var json = false
}

/// 解析命令行参数
func parseArguments() -> Arguments {
    var args = Arguments()
    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--root": if let v = iterator.next() { args.roots.append(v) }
        case "--top": if let v = iterator.next(), let n = Int(v) { args.top = n }
        case "--dormant-days": if let v = iterator.next(), let n = Int(v) { args.dormantDays = n }
        case "--no-global": args.includeGlobal = false
        case "--verify": args.verify = true
        case "--json": args.json = true
        default: FileHandle.standardError.write(Data("未知参数：\(arg)\n".utf8))
        }
    }
    return args
}

/// 字节格式化
func format(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// 调用 du 获取参考体积（实际占用，字节）
func duBytes(_ path: String) -> Int64? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
    process.arguments = ["-sk", path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard let text = String(data: data, encoding: .utf8),
          let first = text.split(separator: "\t").first, let kb = Int64(first) else { return nil }
    return kb * 1024
}

let args = parseArguments()
let options = ScanOptions(
    roots: args.roots.isEmpty ? nil : args.roots, includeGlobal: args.includeGlobal, dormantDays: args.dormantDays)
let engine = ScanEngine(options: options)

var items = [ScanItem]()
var firstResultAt: Double?
var summary: ScanSummary?
var gitRepos = [GitRepoInfo]()
let startTime = Date()

for await event in engine.scan() {
    switch event {
    case .item(let item):
        if firstResultAt == nil { firstResultAt = Date().timeIntervalSince(startTime) }
        items.append(item)
    case .gitRepo(let repo): gitRepos.append(repo)
    case .progress: break
    case .finished(let s): summary = s
    }
}

items.sort { $0.sizeBytes > $1.sizeBytes }

if args.json {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(items), let text = String(data: data, encoding: .utf8) { print(text) }
} else {
    print(String(format: "%-10@ %-10@ %-8@ %@", "体积" as NSString, "等级" as NSString, "栈" as NSString, "路径" as NSString))
    for item in items.prefix(args.top) {
        let line = "\(format(item.sizeBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) "
            + "\(item.level.title.padding(toLength: 6, withPad: " ", startingAt: 0)) "
            + "\(item.stack.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(item.path)"
        print(line)
    }
}

if !gitRepos.isEmpty, !args.json {
    print("\n体积膨胀的 Git 仓库（建议 git gc）：")
    for repo in gitRepos.sorted(by: { $0.gitBytes > $1.gitBytes }).prefix(args.top) {
        print("\(format(repo.gitBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(repo.path)")
    }
}

if let summary {
    let total = items.reduce(Int64(0)) { $0 + $1.sizeBytes }
    FileHandle.standardError.write(Data((
        "\n共 \(summary.totalItems) 项，合计 \(format(total))；访问目录 \(summary.visitedDirectories)，"
        + "跳过 \(summary.skippedDirectories)；"
        + "首个结果 \(String(format: "%.2f", firstResultAt ?? 0)) 秒，总耗时 \(String(format: "%.2f", summary.duration)) 秒\n").utf8))
}

if args.verify {
    FileHandle.standardError.write(Data("\n--- 与 du 对比（前 \(min(args.top, 10)) 项）---\n".utf8))
    for item in items.prefix(min(args.top, 10)) {
        let reference = duBytes(item.path) ?? -1
        let diff = reference > 0 ? Double(item.sizeBytes - reference) / Double(reference) * 100 : 0
        FileHandle.standardError.write(Data(
            "\(format(item.sizeBytes)) vs du \(format(reference))（偏差 \(String(format: "%.2f", diff))%）\(item.path)\n".utf8))
    }
}
