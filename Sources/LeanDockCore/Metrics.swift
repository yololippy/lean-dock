import CPlatform
import Darwin
import Foundation
import IOKit

public enum MemoryMeasurement {
    public static func current() -> (rss: UInt64, footprint: UInt64, cpu: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        return (result == KERN_SUCCESS ? info.resident_size : 0, result == KERN_SUCCESS ? info.phys_footprint : 0, cpu)
    }
}

public final class MetricCollector {
    private let host = mach_host_self()
    private var previousTicks: [UInt32]?
    private var previousProcesses: [Int32: (cpu: Double, time: Double)] = [:]
    private var ownPrevious: (cpu: Double, time: Double)?
    private var lastSample: TimeInterval = -.infinity
    private var lastQuota: TimeInterval = -.infinity
    private var lastPower: TimeInterval = -.infinity
    private var power = MetricValue("--", "fixed")
    private var snapshot = MetricSnapshot()
    private let usage: CodexUsageReader
    private let home: URL
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, cacheDirectory: URL? = nil) {
        self.home = home
        usage = CodexUsageReader(roots: [home.appendingPathComponent(".codex/sessions"), home.appendingPathComponent(".codex/archived_sessions")],
                                cacheURL: cacheDirectory?.appendingPathComponent("quota-cache.json"))
    }
    deinit { mach_port_deallocate(mach_task_self_, host) }

    public func collect(now: Date = Date()) -> MetricSnapshot {
        let monotonic = ProcessInfo.processInfo.systemUptime
        if monotonic - lastSample >= 1.8 {
            lastSample = monotonic
            let memory = memoryPercent()
            snapshot.values[KeyKind.memory.rawValue] = .init(memory.map { "\(Int($0.rounded()))%" } ?? "--", level(memory ?? 0, 70, 90))
            let cpu = cpuPercent()
            snapshot.values[KeyKind.cpu.rawValue] = .init(cpu.map { "\(Int($0.rounded()))%" } ?? "--", level(cpu ?? 0, 60, 85))
            var disk = statfs()
            if statfs("/", &disk) == 0 {
                let free = Double(disk.f_bavail) * Double(disk.f_bsize), total = Double(disk.f_blocks) * Double(disk.f_bsize)
                let percent = total > 0 ? free / total * 100 : 0
                snapshot.values[KeyKind.disk.rawValue] = .init("\(Int((free / pow(1024, 3)).rounded())) GB", percent >= 20 ? "normal" : percent >= 10 ? "attention" : "alert")
            } else { snapshot.values[KeyKind.disk.rawValue] = .init("--", "fixed") }
            var load = [Double](repeating: 0, count: 3)
            if getloadavg(&load, 3) > 0 {
                snapshot.values[KeyKind.load.rawValue] = .init(String(format: "%.1f", load[0]), level(load[0] / Double(ProcessInfo.processInfo.activeProcessorCount), 0.7, 1))
            }
            // Match the old helper's wall time since kern.boottime, including Mac sleep.
            var boot = timeval(), bootSize = MemoryLayout<timeval>.size
            let bootResult = sysctlbyname("kern.boottime", &boot, &bootSize, nil, 0)
            let elapsed = bootResult == 0 ? now.timeIntervalSince1970 - Double(boot.tv_sec) - Double(boot.tv_usec) / 1e6
                                         : ProcessInfo.processInfo.systemUptime
            let uptime = max(0, Int(elapsed))
            let days = uptime / 86400, hours = uptime / 3600 % 24, minutes = uptime / 60 % 60
            snapshot.values[KeyKind.uptime.rawValue] = .init(days > 0 ? "\(days)天\(hours)时" : hours > 0 ? "\(hours)时\(minutes)分" : "\(minutes)分钟", "fixed")
            snapshot.values[KeyKind.codexStatus.rawValue] = CodexStatusReader.read(database: home.appendingPathComponent(".codex/thread_history_1.sqlite"))
            sampleProcesses(at: monotonic)
        }
        if monotonic - lastPower >= 5 { lastPower = monotonic; power = readPower() }
        if monotonic - lastQuota >= 30 { lastQuota = monotonic; usage.scan() }
        snapshot.values[KeyKind.power.rawValue] = power
        snapshot.values[KeyKind.codexUsage.rawValue] = usage.latest?.metric(now: now) ?? .init("--\n--", "fixed")
        snapshot.quotaUpdatedAt = usage.latest?.timestamp
        snapshot.warnings = [usage.lastError].compactMap { $0 }
        let own = MemoryMeasurement.current()
        snapshot.residentBytes = own.rss; snapshot.footprintBytes = own.footprint; snapshot.cpuSeconds = own.cpu
        snapshot.values[KeyKind.appMemory.rawValue] = .init(String(format: "%.1f MB", Double(own.rss) / 1048576))
        if let before = ownPrevious, monotonic - before.time >= 1.8 {
            let percent = max(0, (own.cpu - before.cpu) / (monotonic - before.time) / Double(ProcessInfo.processInfo.activeProcessorCount) * 100)
            snapshot.values[KeyKind.appCPU.rawValue] = .init("\(Int(percent.rounded()))%")
            ownPrevious = (own.cpu, monotonic)
        } else if ownPrevious == nil { ownPrevious = (own.cpu, monotonic) }
        snapshot.updatedAt = now
        return snapshot
    }

    private func level(_ value: Double, _ caution: Double, _ alert: Double) -> String {
        value < caution ? "normal" : value < alert ? "attention" : "alert"
    }
    private func memoryPercent() -> Double? {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        // Match psutil on macOS: available = free + inactive pages.
        let available = (Double(info.free_count) + Double(info.inactive_count)) * Double(pageSize)
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return max(0, min(100, (total - available) / total * 100))
    }
    private func cpuPercent() -> Double? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let values = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
        defer { previousTicks = values }
        guard let previousTicks else { return nil }
        let delta = zip(values, previousTicks).map { Double($0 &- $1) }
        let total = delta.reduce(0, +)
        return total > 0 ? (total - delta[2]) / total * 100 : 0
    }
    private func readPower() -> MetricValue {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard entry != 0 else { return .init("--", "fixed") }
        defer { IOObjectRelease(entry) }
        guard let property = IORegistryEntryCreateCFProperty(entry, "PowerTelemetryData" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
              let value = property["SystemLoad"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else {
            return .init("--", "fixed")
        }
        return .init(String(format: "%.1f W", max(0, value.doubleValue) / 1000))
    }
    private func sampleProcesses(at time: Double) {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 128)
        let bytes = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count)) }
        var rss: UInt64 = 0, cpu: Double = 0, samples: [Int32: (cpu: Double, time: Double)] = [:]
        for pid in pids.prefix(max(0, Int(bytes) / MemoryLayout<pid_t>.size)) where pid > 0 {
            var path = [CChar](repeating: 0, count: Int(LEAN_PROC_PIDPATH_MAX))
            let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            guard length > 0, String(cString: path).contains("/VSD Craft.app/Contents/") else { continue }
            var info = proc_taskinfo()
            let size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
            guard size == MemoryLayout<proc_taskinfo>.size else { continue }
            let seconds = Double(info.pti_total_user + info.pti_total_system) / 1e9
            samples[pid] = (seconds, time); rss += info.pti_resident_size
            if let previous = previousProcesses[pid], time > previous.time { cpu += max(0, seconds - previous.cpu) / (time - previous.time) }
        }
        previousProcesses = samples
        let memoryPercent = Double(rss) / Double(ProcessInfo.processInfo.physicalMemory) * 100
        let cpuPercent = min(100, cpu / Double(ProcessInfo.processInfo.activeProcessorCount) * 100)
        snapshot.values[KeyKind.vsdMemory.rawValue] = .init(samples.isEmpty ? "--" : "\(Int(memoryPercent.rounded()))%", "fixed")
        snapshot.values[KeyKind.vsdCPU.rawValue] = .init(samples.isEmpty ? "--" : "\(Int(cpuPercent.rounded()))%", "fixed")
    }
}
