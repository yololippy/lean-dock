import Foundation
import CPlatform
import Darwin

/// Only this user's vendor bundle, plugins, legacy helper and their children.
public enum VendorProcesses {
    public struct Entry {
        public let pid: Int32
        public let parent: Int32
        public let user: UInt32
        public let executable: String
        public let arguments: String
        public init(pid: Int32, parent: Int32, user: UInt32, executable: String, arguments: String = "") {
            self.pid = pid; self.parent = parent; self.user = user
            self.executable = executable; self.arguments = arguments
        }
    }

    public static func targets(in entries: [Entry], user: UInt32, excluding ownPID: Int32) -> Set<Int32> {
        let eligible = entries.filter { $0.user == user && $0.pid > 1 && $0.pid != ownPID }
        var selected = Set<Int32>()
        for entry in eligible {
            let path = entry.executable.lowercased()
            let interpreter = URL(fileURLWithPath: path).lastPathComponent
            let scriptHost = interpreter.hasPrefix("python") || ["node", "nodejs"].contains(interpreter)
            let command = entry.arguments.lowercased()
            if path.contains("/vsd craft.app/contents/") ||
                path.contains("/library/application support/hotspot/streamdock/plugins/") ||
                (scriptHost && (command.contains("/library/application support/streamdocklights/toggle_lights_server.py") ||
                    command.contains("/library/application support/hotspot/streamdock/plugins/"))) {
                selected.insert(entry.pid)
            }
        }
        var previous = -1
        while previous != selected.count {
            previous = selected.count
            for entry in eligible where selected.contains(entry.parent) { selected.insert(entry.pid) }
        }
        return selected
    }

    private static func snapshot() throws -> [Entry] {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,uid=,args="]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw LeanDockError.message("无法检查 VSD 辅助进程，暂未接管设备。") }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let columns = line.split(maxSplits: 3, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count == 4, let pid = Int32(columns[0]), let parent = Int32(columns[1]), let user = UInt32(columns[2]) else { return nil }
            var path = [CChar](repeating: 0, count: Int(LEAN_PROC_PIDPATH_MAX))
            let size = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            guard size > 0 else { return nil }
            return Entry(pid: pid, parent: parent, user: user, executable: String(cString: path), arguments: String(columns[3]))
        }
    }

    public static func stopAll() throws {
        // Rescan immediately before signaling, rather than acting on old process IDs.
        for attempt in 0..<50 {
            let selected = targets(in: try snapshot(), user: getuid(), excluding: getpid())
            if selected.isEmpty { return }
            for pid in selected { _ = kill(pid, attempt < 30 ? SIGTERM : SIGKILL) }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw LeanDockError.message("仍有 VSD 相关进程未退出，暂未接管设备。")
    }
}
