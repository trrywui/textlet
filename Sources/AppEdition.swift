import Foundation

enum AppEdition {
    static let name = "Textlet"
    static let sessionDirectory = "Textlet"
    static let description = "原生轻量编辑器"
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development" }
#if ROW_RENDERER
    static let renderer = "rows"
#else
    static let renderer = "native"
#endif
}
