import AppKit

func checkLineNumberCache(app: Textlet) throws -> [String: Bool] {
    let oldID = app.activeID!, oldFont = app.editor.font!.pointSize
    let note = Note(name: "line-number-fixture", text: (0..<250).map {
        "\($0) 中文🙂 " + String(repeating: "wide wrapped line ", count: $0 % 4 == 0 ? 30 : 1)
    }.joined(separator: "\r\n") + "\r\n")
    let originalCache = app.ruler.usesLabelCache
    app.notes.append(note)
    defer {
        app.ruler.usesLabelCache = originalCache
        app.setFontSize(oldFont)
        try? app.removeNote(note.record.id)
        try? app.selectNote(oldID)
    }
    try app.selectNote(note.record.id)
    let scale = app.window.backingScaleFactor
    var lastImage: CGImage?
    func pixels(cached: Bool) -> Data {
        app.ruler.usesLabelCache = cached
        let width = Int(app.ruler.bounds.width * scale), height = Int(app.ruler.bounds.height * scale)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        app.ruler.draw(app.ruler.bounds)
        NSGraphicsContext.restoreGraphicsState()
        lastImage = context.makeImage()
        return Data(bytes: context.data!, count: context.bytesPerRow * height)
    }
    var equal = true, comparisons = 0
    for font: CGFloat in [10, 14, 20, 28] {
        app.setFontSize(font)
        for y: CGFloat in [0, 0.25, 27.5, 120.125, 3000] {
            app.scroller.contentView.scroll(to: NSPoint(x: 0, y: y))
            app.window.contentView?.layoutSubtreeIfNeeded(); app.window.displayIfNeeded()
            for (firstLine, continuation) in [(1, false), (9998, false), (12345678, true)] {
                app.ruler.reset(firstLine: firstLine, continuation: continuation)
                // As with row-image comparisons, warm lazy TextKit layout before
                // using native drawing as an oracle for this exact viewport.
                _ = pixels(cached: false); _ = pixels(cached: false)
                let native = pixels(cached: false), nativeImage = lastImage!
                let repeatNative = pixels(cached: false)
                let cached = pixels(cached: true), cachedImage = lastImage!
                let repeatCached = pixels(cached: true)
                if native != cached && equal {
                    let changed = zip(native, cached).filter { $0 != $1 }
                    print("Line number mismatch: font=\(font) y=\(y) first=\(firstLine) bytes=\(changed.count) maxDelta=\(changed.map { abs(Int($0) - Int($1)) }.max() ?? 0)")
                    for (name, image) in [("line-native", nativeImage), ("line-cached", cachedImage)] {
                        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: app.store.directory.appendingPathComponent(name + ".png"))
                    }
                }
                equal = equal && native == repeatNative && native == cached && cached == repeatCached
                comparisons += 1
            }
        }
    }
    return ["lineNumberCachedPixelsMatchNativeAcrossFontsScrollWrapAndContinuation": equal && comparisons == 60,
        "lineNumberCacheHasHits": app.ruler.labelCacheHits > 0,
        "lineNumberCacheIsBounded": app.ruler.cachedLabelCount <= 128]
}
