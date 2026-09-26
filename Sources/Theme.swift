import AppKit

// Shared opaque colors: no visual-effect views, images or extra backing layers.
enum Theme {
    static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    static let canvas = color(0x272822)
    static let chrome = color(0x20211c)
    static let text = color(0xf1f0e8)
    static let muted = color(0xa3a397)
    static let comment = color(0x949587)
    static let accent = color(0xe6b450)
    static let selection = color(0x4b4d3c)
    static let keyword = color(0xf92672)
    static let key = color(0x66d9ef)
    static let string = color(0xe6db74)
    static let value = color(0xae81ff)
}
