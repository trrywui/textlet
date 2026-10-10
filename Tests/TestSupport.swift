import AppKit

/// 只截取当前合成测试窗口，不截取桌面或其他应用。
func captureTestWindow(app: Textlet, to url: URL) {
    guard let image = CGWindowListCreateImage(
        .null,
        .optionIncludingWindow,
        CGWindowID(app.window.windowNumber),
        .boundsIgnoreFraming
    ) else { return }
    try? NSBitmapImageRep(cgImage: image)
        .representation(using: .png, properties: [:])?
        .write(to: url)
}
