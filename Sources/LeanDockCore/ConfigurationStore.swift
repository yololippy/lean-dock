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
