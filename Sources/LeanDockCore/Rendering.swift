import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct KeyFace: Equatable {
    public var kind: KeyKind
    public var text: String
    public var status: String
    public var flashing: Bool = false
    public init(kind: KeyKind, text: String, status: String = "normal", flashing: Bool = false) {
        self.kind = kind; self.text = text; self.status = status; self.flashing = flashing
    }
}

public final class KeyRenderer {
    private let iconsURL: URL
    private var icons: [String: CGImage] = [:]
    private var cached: [String: (face: KeyFace, jpeg: Data)] = [:]
    public private(set) var encodedFrames = 0
    public init(iconsURL: URL? = nil) {
        self.iconsURL = iconsURL ?? Bundle.module.url(forResource: "Icons", withExtension: nil)!
    }
    public var cachedImageCount: Int { cached.count }
    public var cachedBytes: Int { cached.values.reduce(0) { $0 + $1.jpeg.count } }
    public func retainOnly(_ ids: Set<String>) { cached = cached.filter { ids.contains($0.key) } }

    public static func face(for key: KeyConfiguration, snapshot: MetricSnapshot, content: UserContent, now: Date = Date()) -> KeyFace {
        switch key.kind {
        case .empty: return .init(kind: .empty, text: "")
        case .calendar:
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "MMM\nd"
            return .init(kind: .calendar, text: formatter.string(from: now))
        case .clock:
            let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"; formatter.locale = Locale(identifier: "en_US_POSIX")
            return .init(kind: .clock, text: formatter.string(from: now))
        case .notes: return .init(kind: .notes, text: "备忘录\n\(content.notes[key.id]?.count ?? 0) 条")
        case .todo:
            let todo = content.todos[key.id] ?? Todo()
            let expired = !todo.completed && (todo.deadline.map { $0 <= now } ?? false) && !todo.title.isEmpty
            let text = todo.title.isEmpty ? "待办事项" : "\(todo.title.prefix(8))\n\(todo.remaining(at: now))"
            return .init(kind: .todo, text: text, status: expired ? "alert" : "normal",
                         flashing: expired && Int(now.timeIntervalSince1970 / 2) % 2 == 0)
        case .lights: return .init(kind: .lights, text: "")
        case .unsupported: return .init(kind: .unsupported, text: "\(key.label.prefix(8))\n未支持", status: "attention")
        default:
            let value = snapshot.values[key.kind.rawValue] ?? .init("--", "fixed")
            return .init(kind: key.kind, text: value.text, status: value.status)
        }
    }

    public func render(key: KeyConfiguration, face: KeyFace) throws -> Data {
        if let existing = cached[key.id], existing.face == face { return existing.jpeg }
        let image = try draw(face, size: 64)
        let bytes = try Self.encode(image, type: UTType.jpeg.identifier as CFString)
        cached[key.id] = (face, bytes); encodedFrames += 1
        return bytes
    }

    private func icon(_ kind: KeyKind, status: String) -> CGImage? {
        guard var name = kind.iconName else { return nil }
        if [KeyKind.memory, .cpu, .disk, .load, .power, .codexUsage, .appMemory, .appCPU].contains(kind), status != "normal" {
            name = name.replacingOccurrences(of: "-normal", with: "-\(status)")
        }
        if let image = icons[name] { return image }
        let url = iconsURL.appendingPathComponent("\(name).png")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
                [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64,
                 kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        icons[name] = image
        return image
    }

    private func draw(_ face: KeyFace, size: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw LeanDockError.message("无法创建键面画布。")
        }
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        context.setFillColor(Self.color(face.flashing ? "803B49" : "1D201F")); context.fill(bounds)
        if let image = icon(face.kind, status: face.status) { context.draw(image, in: bounds) }
        let textColor = Self.color([KeyKind.vsdCPU, .vsdMemory, .clock, .codexStatus].contains(face.kind) ? "F2F3EC" :
                                    face.status == "alert" ? "A83B49" : face.status == "attention" ? "A85F0A" : face.status == "fixed" ? "277FA0" : "147A69")
        if face.kind == .calendar {
            context.setFillColor(Self.color("DCEEEA")); context.fill(bounds.insetBy(dx: 2, dy: 2))
            context.setFillColor(Self.color("2799CE")); context.fill(CGRect(x: 2, y: 49, width: 60, height: 13))
            let parts = face.text.components(separatedBy: "\n")
            drawText(parts.first ?? "", y: 33, fontSize: 13, color: Self.color("172221"), context: context)
            drawText(parts.last ?? "", y: 7, fontSize: 27, color: Self.color("172221"), context: context)
        } else if face.kind == .notes || face.kind == .todo || face.kind == .unsupported {
            context.setStrokeColor(textColor); context.setLineWidth(2)
            context.stroke(CGRect(x: 22, y: 36, width: 20, height: 20))
            for y in [42, 48] { context.move(to: CGPoint(x: 26, y: y)); context.addLine(to: CGPoint(x: 38, y: y)); context.strokePath() }
            drawLines(face.text, baseline: 17, color: textColor, context: context, fontSize: 10)
        } else if face.kind == .clock {
            drawText(face.text, y: 27, fontSize: 11, color: textColor, context: context)
        } else if face.kind != .empty && face.kind != .lights {
            drawLines(face.text, baseline: face.text.contains("\n") ? 18 : 12, color: textColor, context: context,
                      fontSize: face.kind == .codexStatus ? 10 : 11)
        }
        guard let image = context.makeImage() else { throw LeanDockError.message("无法生成键面图像。") }
        return image
    }

    private func drawLines(_ text: String, baseline: CGFloat, color: CGColor, context: CGContext, fontSize: CGFloat) {
        for (index, line) in text.components(separatedBy: "\n").prefix(3).enumerated() {
            drawText(line, y: baseline - CGFloat(index) * 12, fontSize: fontSize, color: color, context: context)
        }
    }
    private func drawText(_ text: String, y: CGFloat, fontSize: CGFloat, color: CGColor, context: CGContext) {
        var fontSize = fontSize, line: CTLine!
        var width = 0.0
        repeat {
            let font = CTFontCreateWithName("Helvetica Neue Bold" as CFString, fontSize, nil)
            let attributed = CFAttributedStringCreate(nil, text as CFString,
                [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary)!
            line = CTLineCreateWithAttributedString(attributed); width = CTLineGetTypographicBounds(line, nil, nil, nil)
            if width <= 59 || fontSize <= 7 { break }; fontSize -= 0.5
        } while true
        context.textPosition = CGPoint(x: max(2, (64 - width) / 2), y: y); CTLineDraw(line, context)
    }

    private static func color(_ hex: String) -> CGColor {
        let value = UInt32(hex, radix: 16) ?? 0
        return CGColor(red: CGFloat(value >> 16 & 255) / 255, green: CGFloat(value >> 8 & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    private static func encode(_ image: CGImage, type: CFString) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { throw LeanDockError.message("无法编码图像。") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw LeanDockError.message("图像编码失败。") }
        return data as Data
    }
    public static func preview(frames: [Data], at url: URL) throws {
        let width = 720, height = 440
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw LeanDockError.message("无法创建预览。")
        }
        context.setFillColor(color("101514")); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, data) in frames.prefix(15).enumerated() {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            let rect = CGRect(x: 24 + index % 5 * 140, y: 296 - index / 5 * 140, width: 112, height: 112)
            context.draw(image, in: rect)
        }
        guard let image = context.makeImage() else { throw LeanDockError.message("无法输出预览。") }
        try encode(image, type: UTType.png.identifier as CFString).write(to: url, options: .atomic)
    }
}
