import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let entries = [(16, "icon_16x16.png"), (32, "icon_16x16@2x.png"), (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
               (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"), (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
               (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")]
for (size, name) in entries {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.setFillColor(CGColor(red: 0.055, green: 0.10, blue: 0.085, alpha: 1))
    context.addPath(CGPath(roundedRect: CGRect(x: 28, y: 28, width: 968, height: 968), cornerWidth: 215, cornerHeight: 215, transform: nil)); context.fillPath()
    for row in 0..<3 { for column in 0..<5 {
        context.setFillColor(CGColor(red: 0.12, green: row == 1 && column == 2 ? 0.95 : 0.69, blue: 0.49, alpha: 1))
        let rect = CGRect(x: 144 + column * 151, y: 310 + row * 151, width: 128, height: 128)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 27, cornerHeight: 27, transform: nil)); context.fillPath()
    } }
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Icon encoding failed") }
    try (data as Data).write(to: folder.appendingPathComponent(name))
}
