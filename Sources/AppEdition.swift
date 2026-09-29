import Foundation

// Edition identity is independent of rendering: both builds use the same renderer.
enum AppEdition {
#if TEXTLET_EXPERIMENTAL
    static let name = "Textlet 实验版"
    static let sessionDirectory = "Textlet-Rows-Experiment"
    static let description = "逐行绘制实验版 · 独立草稿目录"
#else
    static let name = "Textlet"
    static let sessionDirectory = "Textlet"
    static let description = "原生轻量编辑器"
#endif
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development" }
#if ROW_RENDERER
    static let renderer = "rows"
#else
    static let renderer = "native"
#endif
}
