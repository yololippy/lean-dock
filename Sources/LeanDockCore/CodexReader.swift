import CPlatform
import Foundation

/// Holds at most one bounded, incomplete JSONL record, never a whole log file.
public struct JSONLDecoder {
    public var maximumLineBytes = 1_048_576
    private var pending = Data()
    private var dropping = false
    public init() {}
    public var bufferedBytes: Int { pending.count }
    public mutating func feed(_ chunk: Data, line: (Data) -> Void) {
        let parts = chunk.split(separator: 10, omittingEmptySubsequences: false)
        for (index, part) in parts.enumerated() {
            if !dropping {
                if pending.count + part.count <= maximumLineBytes { pending.append(contentsOf: part) }
                else { pending.removeAll(keepingCapacity: false); dropping = true }
            }
            if index < parts.count - 1 {
                if !dropping, !pending.isEmpty { line(pending) }
                pending.removeAll(keepingCapacity: false); dropping = false
            }
        }
    }
}

public struct QuotaRecord: Codable, Equatable {
    public var timestamp: String
    public var date: Date
    public var primaryUsed: Double
    public var secondaryUsed: Double
    public func metric(now: Date) -> MetricValue {
        let a = max(0, min(100, Int((100 - primaryUsed).rounded(.toNearestOrEven))))
        let b = max(0, min(100, Int((100 - secondaryUsed).rounded(.toNearestOrEven))))
        let age = now.timeIntervalSince(date)
        return .init("5h \(a)%\n周 \(b)%", age < 3600 ? "normal" : age < 86400 ? "attention" : "alert")
    }
}

public final class CodexUsageReader {
    private struct Cursor {
        var inode: UInt64
        var offset: UInt64 = 0
        var decoder = JSONLDecoder()
    }
    private let roots: [URL]
    private let cacheURL: URL?
    private var cursors: [String: Cursor] = [:]
    public private(set) var latest: QuotaRecord?
    public private(set) var lastError: String?
    public init(roots: [URL]? = nil, cacheURL: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.roots = roots ?? [home.appendingPathComponent(".codex/sessions"), home.appendingPathComponent(".codex/archived_sessions")]
        self.cacheURL = cacheURL
        if let cacheURL, let data = try? Data(contentsOf: cacheURL) { latest = try? JSONDecoder().decode(QuotaRecord.self, from: data) }
    }

    public static func record(from data: Data) -> QuotaRecord? {
        // JSONSerialization creates Objective-C containers. Reclaim each record,
        // rather than retaining every temporary object until a full history scan ends.
        return autoreleasepool {
        guard data.range(of: Data("rate_limits".utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any], payload["type"] as? String == "token_count",
              let limits = payload["rate_limits"] as? [String: Any],
              let primary = limits["primary"] as? [String: Any], let secondary = limits["secondary"] as? [String: Any],
              let a = primary["used_percent"] as? NSNumber, let b = secondary["used_percent"] as? NSNumber,
              CFGetTypeID(a) != CFBooleanGetTypeID(), CFGetTypeID(b) != CFBooleanGetTypeID(),
              a.doubleValue.isFinite, b.doubleValue.isFinite,
              let stamp = object["timestamp"] as? String else { return nil }
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = format.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
        guard let date else { return nil }
        return QuotaRecord(timestamp: stamp, date: date, primaryUsed: a.doubleValue, secondaryUsed: b.doubleValue)
        }
    }

    public func scan() {
        var discovered = Set<String>(), readableRoots = 0, hadReadError = false
        var files: [URL] = []
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            readableRoots += 1
            if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                               options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let url as URL in enumerator where url.pathExtension == "jsonl" { files.append(url) }
            }
        }
        // Newest files first makes a recent snapshot available before older history.
        files.sort { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        let previous = latest
        for url in files {
            let path = url.path; discovered.insert(path)
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                var cursor = cursors[path] ?? Cursor(inode: inode)
                if inode != cursor.inode || size < cursor.offset { cursor = Cursor(inode: inode) }
                if size > cursor.offset {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: cursor.offset)
                    // Only read to this scan's EOF, so an active writer cannot keep us in the loop.
                    while cursor.offset < size {
                        let count = min(UInt64(65_536), size - cursor.offset)
                        let consumed = try autoreleasepool { () throws -> Int in
                            guard let chunk = try handle.read(upToCount: Int(count)), !chunk.isEmpty else { return 0 }
                            cursor.decoder.feed(chunk) { [self] line in
                                if let record = Self.record(from: line), latest == nil || record.date > latest!.date { latest = record }
                            }
                            return chunk.count
                        }
                        guard consumed > 0 else { break }
                        cursor.offset += UInt64(consumed)
                    }
                }
                cursors[path] = cursor
            } catch { hadReadError = true }
        }
        cursors = cursors.filter { discovered.contains($0.key) }
        lastError = readableRoots == 0 ? "未找到 Codex 会话日志" : hadReadError ? "部分 Codex 日志暂不可读" : nil
        if latest != previous, let latest, let cacheURL, let data = try? JSONEncoder().encode(latest) {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        }
    }
}

public enum CodexStatusReader {
    public static func read(database: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/thread_history_1.sqlite")) -> MetricValue {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }; return .init("Codex\n?", "fixed")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        let sql = """
        SELECT (SELECT item_json FROM thread_items i WHERE i.thread_id=t.thread_id AND i.turn_id=t.turn_id
          AND i.item_type='agentMessage' ORDER BY rollout_ordinal DESC LIMIT 1)
        FROM thread_turns t WHERE lower(t.status) IN ('inprogress','in_progress','running')
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return .init("Codex\n?", "fixed") }
        defer { sqlite3_finalize(statement) }
        var running = 0, waiting = 0
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { return .init("Codex\n?", "fixed") }
            running += 1
            if let bytes = sqlite3_column_text(statement, 0),
               let data = String(cString: bytes).data(using: .utf8),
               let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               item["phase"] as? String == "final_answer" { waiting += 1 }
        }
        if waiting > 0 { return .init("Codex\n待确认 \(waiting)", "attention") }
        return .init(running > 0 ? "Codex\n忙 \(running)" : "Codex\n就绪")
    }
}
