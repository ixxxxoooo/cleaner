// 本地持久化：扫描缓存、清理历史、白名单（JSON，存于 Application Support）
// @author ygw
import Foundation

/// JSON 文件存储
public struct JSONStore<Value: Codable & Sendable>: Sendable {
    private let url: URL

    /// 创建存储
    /// - Parameters:
    ///   - fileName: 文件名
    ///   - directory: 存储目录，默认 ~/Library/Application Support/Cleaner
    public init(fileName: String, directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cleaner", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent(fileName)
    }

    /// 读取内容
    /// - Returns: 解码结果；文件不存在或损坏时返回 nil
    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Value.self, from: data)
    }

    /// 写入内容（原子写入）
    /// - Parameter value: 待保存内容
    public func save(_ value: Value) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// 缓存快照
public struct ScanSnapshot: Codable, Sendable {
    public var date: Date
    public var items: [ScanItem]

    public init(date: Date, items: [ScanItem]) {
        self.date = date
        self.items = items
    }
}

/// 常用存储实例
public enum Stores {
    public static let scanCache = JSONStore<ScanSnapshot>(fileName: "scan-cache.json")
    public static let history = JSONStore<[CleanRecord]>(fileName: "clean-history.json")
    public static let whitelist = JSONStore<[String]>(fileName: "whitelist.json")
    public static let customRules = JSONStore<[Rule]>(fileName: "custom-rules.json")
}
