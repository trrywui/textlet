import AppKit

private final class TabInsertionIndicator: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        Theme.accent.setFill()
        bounds.intersection(dirtyRect).fill()
    }
}

// One gesture for the whole strip; it never owns a note or its text storage.
final class TabReordering {
    private static let dragThreshold: CGFloat = 4
    private weak var bar: TabBarView?
    private weak var stack: NSStackView?
    private weak var scroller: NSScrollView?
    private weak var pressedTab: NoteTab?
    private var pressedIndex = 0
    private var origin = NSPoint.zero
    private var lastPoint = NSPoint.zero
    private var dragging = false
    private var scrollTimer: Timer?
    private let indicator = TabInsertionIndicator()
    var onMove: ((UUID, Int) -> Void)?

    init(bar: TabBarView, stack: NSStackView, scroller: NSScrollView) {
        self.bar = bar
        self.stack = stack
        self.scroller = scroller
        indicator.isHidden = true
        indicator.setAccessibilityElement(false)
        bar.addSubview(indicator)
    }

    deinit { scrollTimer?.invalidate() }

    func begin(_ tab: NoteTab, with event: NSEvent) {
        cancel()
        guard let index = stack?.arrangedSubviews.firstIndex(of: tab) else { return }
        pressedTab = tab
        pressedIndex = index
        origin = event.locationInWindow
        lastPoint = origin
    }

    func drag(_ tab: NoteTab, with event: NSEvent) {
        guard pressedTab === tab else { return }
        let point = event.locationInWindow
        lastPoint = point
        if hasReachedDragThreshold(at: point) { dragging = true }
        guard dragging else { return }
        updatePreview()
    }

    func end(_ tab: NoteTab, with event: NSEvent) {
        guard pressedTab === tab else { return }
        let wasDragging = dragging || hasReachedDragThreshold(at: event.locationInWindow)
        let target = wasDragging ? destination(at: event.locationInWindow)?.index : nil
        let oldIndex = pressedIndex
        let clicked = tab.visibleRect.contains(tab.convert(event.locationInWindow, from: nil))
        cancel()
        if wasDragging {
            if let target, target != oldIndex { onMove?(tab.id, target) }
        } else if clicked {
            tab.onSelect?()
        }
    }

    @discardableResult func cancel() -> Bool {
        let hadPress = pressedTab != nil
        pressedTab = nil
        dragging = false
        indicator.isHidden = true
        stopScrolling()
        return hadPress
    }

    private func hasReachedDragThreshold(at point: NSPoint) -> Bool {
        let dx = point.x - origin.x, dy = point.y - origin.y
        return dx * dx + dy * dy >= Self.dragThreshold * Self.dragThreshold
    }

    private func updatePreview() {
        guard let destination = destination(at: lastPoint) else {
            indicator.isHidden = true
            stopScrolling()
            return
        }
        if indicator.frame != destination.marker { indicator.frame = destination.marker }
        indicator.isHidden = false
        guard scrollStep() != 0 else { stopScrolling(); return }
        guard scrollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.scrollAtEdge() }
        timer.tolerance = 0.01
        scrollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func stopScrolling() {
        scrollTimer?.invalidate()
        scrollTimer = nil
    }

    private func scrollStep() -> CGFloat {
        guard dragging, pressedTab != nil, let stack, let clip = scroller?.contentView else { return 0 }
        let point = clip.convert(lastPoint, from: nil)
        let viewport = clip.bounds
        guard viewport.contains(point) else { return 0 }
        let maximum = max(0, stack.bounds.maxX - viewport.width)
        if point.x < viewport.minX + 24, viewport.minX > 0 { return -min(18, viewport.minX) }
        if point.x > viewport.maxX - 24, viewport.minX < maximum { return min(18, maximum - viewport.minX) }
        return 0
    }

    private func scrollAtEdge() {
        let step = scrollStep()
        guard step != 0, let scroller else { stopScrolling(); return }
        let clip = scroller.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX + step, y: clip.bounds.minY))
        scroller.reflectScrolledClipView(clip)
        updatePreview()
    }

    private func destination(at point: NSPoint) -> (index: Int, marker: NSRect)? {
        guard let bar, let stack, let clip = scroller?.contentView else { return nil }
        let clipPoint = clip.convert(point, from: nil)
        guard clip.bounds.contains(clipPoint) else { return nil }
        let tabs = stack.arrangedSubviews
        guard pressedIndex < tabs.count, tabs[pressedIndex] === pressedTab else { return nil }
        let x = stack.convert(point, from: nil).x
        // Tab midpoints are ordered; locating a slot needs no per-event ID array.
        var lower = 0, upper = tabs.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if x < tabs[middle].frame.midX { upper = middle }
            else { lower = middle + 1 }
        }
        let slot = lower
        let edge = slot < tabs.count ? tabs[slot].frame.minX - stack.spacing / 2
                                    : tabs[tabs.count - 1].frame.maxX + stack.spacing / 2
        let position = bar.convert(NSPoint(x: edge, y: tabs[0].frame.minY), from: stack)
        let visible = bar.convert(clip.bounds, from: clip)
        let marker = NSRect(x: max(visible.minX, min(visible.maxX - 2, position.x - 1)),
                            y: position.y, width: 2, height: tabs[0].frame.height).intersection(visible)
        return (slot > pressedIndex ? slot - 1 : slot, marker)
    }
}
