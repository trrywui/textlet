import AppKit

// Textlet / concept 01. Geometry and sRGB colors match AppIcon.svg (512 × 512).
// This runs only when generating the static icon, never inside the editor.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func color(_ red: Int, _ green: Int, _ blue: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255, alpha: 1)
}
for (name, size) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),
                     ("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),
                     ("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current!.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(size) / 512)
    transform.concat()
    color(0x24, 0x25, 0x1F).setFill()
    NSBezierPath(roundedRect: NSRect(x: 28, y: 28, width: 456, height: 456),
                 xRadius: 100, yRadius: 100).fill()
    let letter = NSBezierPath()
    let points: [(CGFloat, CGFloat)] = [(140,146),(296,146),(296,202),(284,202),
                                        (284,374),(228,374),(228,202),(140,202)]
    for (index, point) in points.enumerated() {
        let native = NSPoint(x: point.0, y: 512 - point.1)
        if index == 0 { letter.move(to: native) } else { letter.line(to: native) }
    }
    letter.close()
    color(0xEE, 0xED, 0xE4).setFill()
    letter.fill()
    color(0xE6, 0xB4, 0x50).setFill()
    NSRect(x: 308, y: 512 - 202, width: 64, height: 56).fill()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
}
