// Run from the repository root: swift scripts/generate-app-icon.swift
// Vector artwork rendered directly at every required size; no transparent pixels.
import AppKit

let output = URL(fileURLWithPath: "ios/RayBridge/Assets.xcassets/AppIcon.appiconset")
let slots: [(String, Double, Int)] = [
    ("iphone", 20, 2), ("iphone", 20, 3), ("iphone", 29, 2), ("iphone", 29, 3),
    ("iphone", 40, 2), ("iphone", 40, 3), ("iphone", 60, 2), ("iphone", 60, 3),
    ("ipad", 20, 1), ("ipad", 20, 2), ("ipad", 29, 1), ("ipad", 29, 2),
    ("ipad", 40, 1), ("ipad", 40, 2), ("ipad", 76, 1), ("ipad", 76, 2),
    ("ipad", 83.5, 2), ("ios-marketing", 1024, 1)
]
var images: [[String: String]] = []
for (idiom, points, scale) in slots {
    let pixels = Int(points * Double(scale))
    let size = points == points.rounded() ? String(Int(points)) : String(points)
    let name = "AppIcon-\(idiom)-\(size)@\(scale)x.png"
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                            bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()
    NSColor(srgbRed: 0.035, green: 0.09, blue: 0.17, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()
    NSColor(srgbRed: 0.25, green: 0.87, blue: 0.9, alpha: 1).setStroke()
    for x in [CGFloat(158), CGFloat(566)] {
        let lens = NSBezierPath(roundedRect: NSRect(x: x, y: 332, width: 300, height: 292), xRadius: 88, yRadius: 88)
        lens.lineWidth = 52
        lens.stroke()
    }
    let bridge = NSBezierPath()
    bridge.move(to: NSPoint(x: 458, y: 522))
    bridge.curve(to: NSPoint(x: 566, y: 522), controlPoint1: NSPoint(x: 490, y: 560), controlPoint2: NSPoint(x: 534, y: 560))
    bridge.lineWidth = 52; bridge.lineCapStyle = .round; bridge.stroke()
    let arms = NSBezierPath()
    arms.move(to: NSPoint(x: 158, y: 556)); arms.line(to: NSPoint(x: 108, y: 592))
    arms.move(to: NSPoint(x: 866, y: 556)); arms.line(to: NSPoint(x: 916, y: 592))
    arms.lineWidth = 52; arms.lineCapStyle = .round; arms.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    images.append(["idiom": idiom, "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("Contents.json"))
