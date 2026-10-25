import Foundation

public final class ConfigurationStore {
    private struct SavedState: Codable {
        var configuration: AppConfiguration
        var content: UserContent
    }
    public let directory: URL
    public var configURL: URL { directory.appendingPathComponent("config.json") }
    public var contentURL: URL { directory.appendingPathComponent("content.json") }
    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LeanDock")) {
        self.directory = directory
    }
    public func loadConfiguration() throws -> AppConfiguration? {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }
        let data = try Data(contentsOf: configURL)
        if let state = try? JSONDecoder().decode(SavedState.self, from: data) { return try state.configuration.validated() }
        return try JSONDecoder().decode(AppConfiguration.self, from: data).validated()
    }
    public func loadContent() throws -> UserContent {
        if FileManager.default.fileExists(atPath: configURL.path),
           let state = try? JSONDecoder().decode(SavedState.self, from: Data(contentsOf: configURL)) { return state.content }
        guard FileManager.default.fileExists(atPath: contentURL.path) else { return .init() }
        return try JSONDecoder().decode(UserContent.self, from: Data(contentsOf: contentURL))
    }
    public func save(_ configuration: AppConfiguration) throws {
        try save(configuration: configuration, content: loadContent())
    }
    public func save(_ content: UserContent) throws {
        guard let configuration = try loadConfiguration() else { throw LeanDockError.message("请先保存布局配置。") }
        try save(configuration: configuration, content: content)
    }
    /// One atomic file keeps key IDs and their note/todo data consistent across a crash.
    public func save(configuration: AppConfiguration, content: UserContent) throws {
        _ = try configuration.validated()
        try write(SavedState(configuration: configuration, content: content), to: configURL)
    }
    public func backup() throws {
        let folder = directory.appendingPathComponent("Backups/\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for url in [configURL, contentURL] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
        }
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public struct ImportResult {
    public var configuration: AppConfiguration
    public var content: UserContent
    public var warnings: [String]
}
public enum VSDImporter {
    public static func currentProfile(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let root = home.appendingPathComponent("Library/Application Support/HotSpot/StreamDock")
        let ini = try String(contentsOf: root.appendingPathComponent("config/StreamDockConfig.plist"), encoding: .utf8)
        var section = ""
        for raw in ini.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line }
            if section.hasPrefix("[M18"), section.contains("DeviceConfig"), line.hasPrefix("sdProfilePath=") {
                let value = String(line.dropFirst("sdProfilePath=".count))
                let url = URL(fileURLWithPath: value)
                if FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) { return url }
            }
        }
        throw LeanDockError.message("没有找到当前 M18 的 VSD 场景。可使用默认两页布局。")
    }

    public static func read(profile: URL) throws -> ImportResult {
        let data = try readObject(profile.appendingPathComponent("manifest.json"))
        guard ["M18V25E", "VSDM18", "M18V3", "M18V2", "M18V25"].contains(data["DeviceUUID"] as? String ?? "") else {
            throw LeanDockError.message("此场景不是受支持的 M18 场景。")
        }
        let pageInfo = data["Pages"] as? [String: Any]
        let ids = pageInfo?["Pages"] as? [String] ?? [profile.lastPathComponent]
        guard ids.count <= 100 else { throw LeanDockError.message("场景页数过多。") }
        var pages: [DeckPage] = [], content = UserContent(), warnings: [String] = []
        for (index, id) in ids.enumerated() {
            guard !id.contains("/"), !id.contains("..") else { throw LeanDockError.message("场景包含无效的页面路径。") }
            let pageURL = id == profile.lastPathComponent ? profile : profile.appendingPathComponent("profiles/\(id)")
            let pageData = try readObject(pageURL.appendingPathComponent("manifest.json"))
            var keys = (0..<15).map { _ in KeyConfiguration(kind: .empty) }
            for (coordinate, raw) in pageData["Actions"] as? [String: Any] ?? [:] {
                let xy = coordinate.split(separator: ",").compactMap { Int($0) }
                guard xy.count == 2, (0..<5).contains(xy[0]), (0..<3).contains(xy[1]),
                      let action = raw as? [String: Any] else { continue }
                let position = (2 - xy[1]) * 5 + xy[0]
                let uuid = action["UUID"] as? String ?? ""
                let kind = kindForUUID(uuid)
                let key = KeyConfiguration(kind: kind, label: action["Name"] as? String ?? kind.title,
                                           id: action["ActionID"] as? String ?? UUID().uuidString, originalUUID: uuid)
                keys[position] = key
                if kind == .unsupported { warnings.append("第 \(index + 1) 页位置 \(position + 1)：\(key.label) 尚未支持，已保留占位。") }
                let settings = action["Settings"] as? [String: Any] ?? [:]
                if kind == .notes {
                    content.notes[key.id] = (settings["list"] as? [[String: Any]] ?? []).map {
                        Note(title: $0["title"] as? String ?? "", content: $0["content"] as? String ?? "")
                    }
                } else if kind == .todo {
                    var todo = Todo(); todo.title = settings["title"] as? String ?? ""
                    todo.content = settings["content"] as? String ?? ""; todo.deadline = parseDate(settings["time"])
                    content.todos[key.id] = todo
                }
            }
            pages.append(.init(name: index == 0 ? "仪表盘" : "第 \(index + 1) 页", keys: keys, id: id))
        }
        var config = AppConfiguration(pages: pages)
        config.device.serial = data["DeviceSerialNumber"] as? String
        config.importedFrom = profile.path
        return ImportResult(configuration: try config.validated(), content: content, warnings: warnings)
    }

    public static func kindForUUID(_ uuid: String) -> KeyKind {
        if uuid.hasPrefix("com.yololippy.streamdock.togglelights.") {
            let suffix = String(uuid.split(separator: ".").last ?? "")
            let mapping: [String: KeyKind] = ["toggle": .lights, "codexstatus": .codexStatus,
                "codexusage": .codexUsage, "vsdcraftcpu": .vsdCPU, "vsdcraftmemory": .vsdMemory]
            return mapping[suffix] ?? KeyKind(rawValue: suffix) ?? .unsupported
        }
        switch uuid {
        case "com.mirabox.streamdock.calendar.action1": return .calendar
        case "com.mirabox.streamdock.dateTime.action1": return .clock
        case "com.hotspot.streamdock.memo.action1": return .notes
        case "com.hotspot.streamdock.memo.action2": return .todo
        default: return .unsupported
        }
    }
    private static func readObject(_ url: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw LeanDockError.message("场景文件格式不正确。")
        }
        return object
    }
    private static func parseDate(_ value: Any?) -> Date? {
        if let n = value as? Double { return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }
        guard let text = value as? String else { return nil }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = pattern
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
