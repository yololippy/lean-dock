// IOHID lifecycle and image transactions informed by stevemurr/streamdock (MIT).
// See THIRD_PARTY_NOTICES.md for attribution and license.
import Foundation
import IOKit.hid

private final class HIDContext {
    weak var owner: M18Device?
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 513)
    let cancelled = DispatchSemaphore(value: 0)
    init(owner: M18Device) { self.owner = owner; buffer.initialize(repeating: 0, count: 513) }
    deinit { buffer.deinitialize(count: 513); buffer.deallocate() }
}

public final class M18Device {
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var context: HIDContext?
    private let callbacks = DispatchQueue(label: "com.yololippy.LeanDock.hid-callbacks")
    public var onInput: ((ButtonEvent) -> Void)?
    public var onRemoval: (() -> Void)?
    public init() {}
    deinit { close() }
    public var isOpen: Bool { device != nil }

    public func open(configuration: DeviceConfiguration) throws {
        close()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: configuration.vendorID, kIOHIDProductIDKey: configuration.productID,
                                              kIOHIDPrimaryUsagePageKey: 0xFFA0, kIOHIDPrimaryUsageKey: 1] as CFDictionary)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { throw error("打开设备管理器", result) }
        guard let found = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)); throw LeanDockError.message("未找到 M18，请检查 USB 连接。")
        }
        let matches = found.filter { candidate in
            guard let serial = configuration.serial, !serial.isEmpty else { return true }
            return IOHIDDeviceGetProperty(candidate, kIOHIDSerialNumberKey as CFString) as? String == serial
        }
        guard matches.count == 1, let selected = matches.first else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw LeanDockError.message(matches.isEmpty ? "未找到配置指定的 M18。" : "发现多个 M18，请在配置中指定序列号。")
        }
        let opened = IOHIDDeviceOpen(selected, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)); throw error("打开 M18", opened)
        }
        let context = HIDContext(owner: self)
        self.manager = manager; self.device = selected; self.context = context
        IOHIDDeviceRegisterInputReportCallback(selected, context.buffer, 513, leanDockInput,
                                              Unmanaged.passUnretained(context).toOpaque())
        IOHIDDeviceRegisterRemovalCallback(selected, leanDockRemoved, Unmanaged.passUnretained(context).toOpaque())
        IOHIDDeviceSetDispatchQueue(selected, callbacks)
        // The block retains the input buffer until cancellation completes, even on timeout.
        IOHIDDeviceSetCancelHandler(selected) { [context] in context.cancelled.signal() }
        IOHIDDeviceActivate(selected)
    }
    public func close() {
        let oldDevice = device, oldManager = manager, oldContext = context
        device = nil; manager = nil; context = nil
        if let oldDevice {
            IOHIDDeviceCancel(oldDevice)
            _ = oldContext?.cancelled.wait(timeout: .now() + 2)
            IOHIDDeviceClose(oldDevice, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let oldManager { IOHIDManagerClose(oldManager, IOOptionBits(kIOHIDOptionsTypeNone)) }
    }
    /// Call only from the owning engine queue; a complete image transaction stays serialized.
    public func write(_ packet: Data) throws {
        guard let device, packet.count == M18Protocol.packetSize else { throw LeanDockError.message("M18 未连接或报告长度无效。") }
        let result = packet.withUnsafeBytes { raw in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, raw.bindMemory(to: UInt8.self).baseAddress!, raw.count)
        }
        guard result == kIOReturnSuccess else { throw error("写入 M18", result) }
    }
    public func image(position: Int, jpeg: Data) throws {
        for packet in try M18Protocol.imagePackets(position: position, jpeg: jpeg) { try write(packet) }
    }
    private func error(_ operation: String, _ code: IOReturn) -> LeanDockError {
        .message("\(operation)失败（IOKit \(String(format: "0x%08X", UInt32(bitPattern: code)))）。若系统提示权限，请为 LeanDock 授权后重新连接。")
    }
}

private let leanDockInput: IOHIDReportCallback = { context, result, _, _, _, report, length in
    guard result == kIOReturnSuccess, let context else { return }
    let holder = Unmanaged<HIDContext>.fromOpaque(context).takeUnretainedValue()
    if let event = M18Protocol.input(Data(bytes: report, count: length)) { holder.owner?.onInput?(event) }
}
private let leanDockRemoved: IOHIDCallback = { context, _, _ in
    guard let context else { return }
    let holder = Unmanaged<HIDContext>.fromOpaque(context).takeUnretainedValue()
    holder.owner?.onRemoval?()
}
