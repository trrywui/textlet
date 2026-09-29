import AppKit

extension Textlet {
    // Persist the actual frame, which also covers title-bar zoom. If a display
    // is removed or its resolution changes, keep the restored window reachable.
    static func visibleWindowFrame(_ frame: NSRect, screens: [NSRect], minimum: NSSize) -> NSRect? {
        guard [frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy({ $0.isFinite }),
              frame.size.width > 0, frame.size.height > 0, let fallback = screens.first else { return nil }
        let screen = screens.max { a, b in
            let left = frame.intersection(a), right = frame.intersection(b)
            return (left.isNull ? 0 : left.width * left.height) < (right.isNull ? 0 : right.width * right.height)
        }.flatMap { frame.intersects($0) ? $0 : nil } ?? fallback
        let width = min(max(frame.width, minimum.width), screen.width)
        let height = min(max(frame.height, minimum.height), screen.height)
        return NSRect(x: min(max(frame.minX, screen.minX), screen.maxX - width),
                      y: min(max(frame.minY, screen.minY), screen.maxY - height),
                      width: width, height: height)
    }
}
