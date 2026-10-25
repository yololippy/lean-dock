import Foundation

public enum KeyKind: String, Codable, CaseIterable {
    case empty, uptime, memory, cpu, disk, load, calendar, clock, codexStatus, codexUsage, power
    case vsdMemory, vsdCPU, appMemory, appCPU, lights, notes, todo, unsupported

    public var title: String {
        switch self {
        case .empty: return "空白"
        case .uptime: return "运行时间"
        case .memory: return "内存使用率"
        case .cpu: return "CPU 使用率"
        case .disk: return "磁盘剩余"
        case .load: return "系统负载"
        case .calendar: return "日历"
        case .clock: return "时钟"
        case .codexStatus: return "Codex 状态"
        case .codexUsage: return "Codex 额度"
        case .power: return "整机功耗"
        case .vsdMemory: return "VSD 内存"
        case .vsdCPU: return "VSD CPU"
        case .appMemory: return "LeanDock 内存"
        case .appCPU: return "LeanDock CPU"
        case .lights: return "灯光开关"
        case .notes: return "备忘录"
        case .todo: return "待办事项"
        case .unsupported: return "未支持的原动作"
        }
    }

    public var iconName: String? {
        switch self {
        case .uptime: return "uptime-fixed"
        case .memory, .appMemory: return "memory-normal"
        case .cpu, .appCPU: return "cpu-normal"
        case .vsdMemory: return "memory-vsd"
        case .vsdCPU: return "cpu-vsd"
        case .disk: return "disk-normal"
        case .load: return "load-normal"
        case .power: return "power-normal"
        case .codexUsage: return "quota-normal"
        case .codexStatus: return "codex"
        case .lights: return "toggle"
        default: return nil
        }
    }
}

public struct KeyConfiguration: Codable, Identifiable, Equatable {
    public var id: String
    public var kind: KeyKind
    public var label: String
    public var originalUUID: String?
    public init(kind: KeyKind, label: String = "", id: String = UUID().uuidString, originalUUID: String? = nil) {
        self.id = id; self.kind = kind; self.label = label; self.originalUUID = originalUUID
    }
}

public struct DeckPage: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var keys: [KeyConfiguration]
    public init(name: String, keys: [KeyConfiguration], id: String = UUID().uuidString) {
        self.id = id; self.name = name; self.keys = keys
    }
}

public struct DeviceConfiguration: Codable, Equatable {
    public var vendorID: Int = 0x6603
    public var productID: Int = 0x1012
    public var serial: String? = nil
    public var screenBrightness: Int = 25
    public var ringBrightness: Int = 100
    public init() {}
}

public struct AppConfiguration: Codable, Equatable {
    public var schemaVersion: Int = 1
    public var device = DeviceConfiguration()
    public var pages: [DeckPage]
    public var importedFrom: String?
    // Retained only for compatibility with 0.1.0 saved configurations; quitting never restores VSD.
    public var restoreVendorOnQuit = false
    public var connectOnLaunch = true
    public var nativeDefaultsVersion: Int?
    public init(pages: [DeckPage]) { self.pages = pages }

    public static var standard: Self {
        let kinds: [KeyKind] = [.uptime, .memory, .cpu, .disk, .load,
                                .calendar, .clock, .codexStatus, .codexUsage, .power,
                                .empty, .appMemory, .appCPU, .empty, .lights]
        var second = (0..<15).map { _ in KeyConfiguration(kind: .empty) }
        second[0] = .init(kind: .notes); second[1] = .init(kind: .todo)
        return .init(pages: [.init(name: "仪表盘", keys: kinds.map { .init(kind: $0) }),
                             .init(name: "备忘录", keys: second)])
    }

    /// Exchange whole keys, preserving IDs and all note/todo references. An empty target moves the key.
    public func relocatingKey(id keyID: String, inPage pageID: String, to position: Int) throws -> Self {
        guard let page = pages.firstIndex(where: { $0.id == pageID }),
              (0..<15).contains(position), pages[page].keys.count == 15,
              let source = pages[page].keys.firstIndex(where: { $0.id == keyID }),
              pages[page].keys[source].kind != .empty else {
            throw LeanDockError.message("键位已变化，无法移动。请重新拖动当前页面中的图标。")
        }
        var next = self
        next.pages[page].keys.swapAt(source, position)
        return try next.validated()
    }

    /// Apply once to existing installations without changing key IDs or note data.
    public func applyingNativeDefaults() -> Self {
        guard nativeDefaultsVersion == nil else { return self }
        var next = self
        next.restoreVendorOnQuit = false
        next.connectOnLaunch = true
        if !next.pages.isEmpty, next.pages[0].keys.count == 15 {
            for (position, oldKind, newKind) in [(11, KeyKind.vsdMemory, KeyKind.appMemory),
                                                (12, KeyKind.vsdCPU, KeyKind.appCPU)] {
                if next.pages[0].keys[position].kind == oldKind {
                    next.pages[0].keys[position].kind = newKind
                    next.pages[0].keys[position].label = newKind.title
                }
            }
        }
        next.nativeDefaultsVersion = 1
        return next
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1, !pages.isEmpty, pages.count <= 100,
              pages.allSatisfy({ $0.keys.count == 15 }),
              Set(pages.map(\.id)).count == pages.count,
              Set(pages.flatMap(\.keys).map(\.id)).count == pages.count * 15,
              (0...100).contains(device.ringBrightness), (1...100).contains(device.screenBrightness),
              device.vendorID == 0x6603, [0x1009, 0x1012].contains(device.productID) else {
            throw LeanDockError.message("配置无效：需要受支持的 M18、15 个键位和有效亮度。")
        }
        return self
    }
}

public struct Note: Codable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var content: String
    public var modifiedAt: Date
    public init(id: String = UUID().uuidString, title: String = "", content: String = "", modifiedAt: Date = Date()) {
        self.id = id; self.title = title; self.content = content; self.modifiedAt = modifiedAt
    }
}
public struct Todo: Codable, Equatable {
    public var title: String = ""
    public var content: String = ""
    public var deadline: Date?
    public var completed: Bool = false
    public init() {}
    public func remaining(at now: Date) -> String {
        guard let deadline, !title.isEmpty else { return "待办" }
        if completed { return "已完成" }
        let seconds = Int(ceil(deadline.timeIntervalSince(now)))
        guard seconds > 0 else { return "Time out" }
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}
public struct UserContent: Codable, Equatable {
    public var notes: [String: [Note]] = [:]
    public var todos: [String: Todo] = [:]
    public init() {}
}

public struct MetricValue: Codable, Equatable {
    public var text: String
    public var status: String
    public init(_ text: String, _ status: String = "normal") { self.text = text; self.status = status }
}
public struct MetricSnapshot: Codable {
    public var values: [String: MetricValue] = [:]
    public var updatedAt = Date()
    public var quotaUpdatedAt: String?
    public var residentBytes: UInt64 = 0
    public var footprintBytes: UInt64 = 0
    public var cpuSeconds: Double = 0
    public var warnings: [String] = []
    public init() {}
}

public enum LeanDockError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
