import Foundation

public enum M18Protocol {
    public static let packetSize = 1024
    public static let slots: [UInt8] = [11, 12, 13, 14, 15, 6, 7, 8, 9, 10, 1, 2, 3, 4, 5]
    public static func command(_ bytes: Data) -> Data {
        precondition(bytes.count + 5 <= packetSize)
        var packet = Data([0x43, 0x52, 0x54, 0, 0]); packet.append(bytes)
        packet.append(Data(repeating: 0, count: packetSize - packet.count)); return packet
    }
    public static func verb(_ text: String) -> Data { command(Data(text.utf8)) }
    public static var mode: Data { command(Data([0x4d, 0x4f, 0x44, 0, 0, 0x33])) }
    public static var clear: Data { command(Data([0x43, 0x4c, 0x45, 0, 0, 0, 0xff])) }
    public static func brightness(_ value: Int) -> Data { command(Data([0x4c, 0x49, 0x47, 0, 0, UInt8(clamping: max(0, min(100, value)))])) }
    public static func ring(_ value: Int) -> Data { command(Data([0x4c, 0x42, 0x4c, 0x49, 0x47, UInt8(clamping: max(0, min(100, value)))])) }
    public static func imagePackets(position: Int, jpeg: Data) throws -> [Data] {
        guard slots.indices.contains(position), !jpeg.isEmpty, jpeg.count <= 262_144 else { throw LeanDockError.message("键面位置或图像大小无效。") }
        var length = UInt32(jpeg.count).bigEndian
        var begin = Data("BAT".utf8); withUnsafeBytes(of: &length) { begin.append(contentsOf: $0) }; begin.append(slots[position])
        var packets = [command(begin)]
        for offset in stride(from: 0, to: jpeg.count, by: packetSize) {
            let end = min(offset + packetSize, jpeg.count)
            var chunk = jpeg.subdata(in: offset..<end); chunk.append(Data(repeating: 0, count: packetSize - chunk.count)); packets.append(chunk)
        }
        packets.append(verb("STP")); return packets
    }
    public static func input(_ data: Data) -> ButtonEvent? {
        guard data.count >= 11, data.prefix(9) == Data([0x41, 0x43, 0x4b, 0, 0, 0x4f, 0x4b, 0, 0]), data[10] <= 1 else { return nil }
        let code = data[9], position: Int
        if (1...15).contains(code) { position = Int(code - 1) }
        else if let index = [UInt8(0x25), 0x30, 0x31].firstIndex(of: code) { position = 15 + index }
        else { return nil }
        return ButtonEvent(position: position, isDown: data[10] == 1)
    }
}
public struct ButtonEvent {
    public let position: Int
    public let isDown: Bool
    public init(position: Int, isDown: Bool) { self.position = position; self.isDown = isDown }
}
public enum InputAction: Equatable { case none, activate(Int), wake }
public struct InputGate {
    private var last: [Int: Double] = [:]
    private var consumeRelease: Int?
    public init() {}
    public mutating func accept(_ event: ButtonEvent, asleep: Bool, lightPosition: Int?, now: Double) -> InputAction {
        guard (0..<18).contains(event.position) else { return .none }
        if consumeRelease == event.position {
            if !event.isDown { consumeRelease = nil }; return .none
        }
        if asleep {
            guard event.position < 15, lightPosition == nil || lightPosition == event.position,
                  now - (last[event.position] ?? -.infinity) >= 0.45 else { return .none }
            if event.isDown { consumeRelease = event.position }
            last[event.position] = now; return .wake
        }
        guard !event.isDown, now - (last[event.position] ?? -.infinity) >= 0.45 else { return .none }
        last[event.position] = now; return .activate(event.position)
    }
}
public enum LightingState: String { case awake, asleep, unknown }
public struct LightingController {
    public private(set) var state: LightingState = .awake
    public init() {}
    public mutating func apply(on: Bool, config: DeviceConfiguration, write: (Data) throws -> Void) throws {
        let packets = on ? [M18Protocol.verb("DIS"), M18Protocol.brightness(config.screenBrightness), M18Protocol.ring(config.ringBrightness)]
                         : [M18Protocol.ring(0), M18Protocol.verb("HAN")]
        do { for packet in packets { try write(packet) }; state = on ? .awake : .asleep }
        catch { state = .unknown; throw error }
    }
}
