import AppKit

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    static func with(displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == displayID }
    }
}

/// A rectangle on one display, in points from that display's top-left corner.
struct ScreenArea: Equatable {
    var displayID: CGDirectDisplayID
    var rect: CGRect

    /// The same rectangle in AppKit's global, bottom-left-origin coordinates.
    var appKitFrame: CGRect? {
        guard let screen = NSScreen.with(displayID: displayID) else { return nil }
        return CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    /// A `width` x `height` area centred on the given screen, shrunk to fit if needed.
    static func centered(width: CGFloat, height: CGFloat, on screen: NSScreen) -> ScreenArea {
        let w = min(width, screen.frame.width), h = min(height, screen.frame.height)
        let rect = CGRect(x: ((screen.frame.width - w) / 2).rounded(), y: ((screen.frame.height - h) / 2).rounded(), width: w, height: h)
        return ScreenArea(displayID: screen.displayID, rect: rect)
    }
}

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Full-screen overlay for dragging out a capture area. Esc cancels.
@MainActor
final class AreaSelector {
    private static var current: AreaSelector?
    private var windows: [NSWindow] = []
    private let completion: (ScreenArea?) -> Void

    static func select(completion: @escaping (ScreenArea?) -> Void) {
        current?.finish(nil)
        let selector = AreaSelector(completion: completion)
        current = selector
        selector.show()
    }

    private init(completion: @escaping (ScreenArea?) -> Void) {
        self.completion = completion
    }

    private func show() {
        for screen in NSScreen.screens {
            let window = KeyableWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.onFinish = { [weak self] rect in
                guard let self else { return }
                guard let rect else { return self.finish(nil) }
                // View coordinates are bottom-left based; areas are top-left based.
                let flipped = CGRect(x: rect.minX, y: screen.frame.height - rect.maxY, width: rect.width, height: rect.height)
                self.finish(ScreenArea(displayID: screen.displayID, rect: flipped.integral))
            }
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.push()
    }

    private func finish(_ area: ScreenArea?) {
        guard AreaSelector.current === self else { return }
        AreaSelector.current = nil
        NSCursor.pop()
        windows.forEach { $0.orderOut(nil) }
        windows = []
        completion(area)
    }
}

private final class SelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private var origin: CGPoint?
    private var selection: CGRect?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        origin = convert(event.locationInWindow, from: nil)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
                           width: abs(point.x - origin.x), height: abs(point.y - origin.y)).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let selection, selection.width >= 32, selection.height >= 32 {
            onFinish?(selection)
        } else {
            origin = nil
            selection = nil
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        guard let selection else {
            let hint = NSAttributedString(string: "Drag to choose the area to record. Esc to cancel.", attributes: attributes)
            let size = hint.size()
            hint.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY))
            return
        }
        NSColor.clear.setFill()
        selection.fill(using: .copy)
        NSColor.systemRed.setStroke()
        let outline = NSBezierPath(rect: selection.insetBy(dx: -1, dy: -1))
        outline.lineWidth = 2
        outline.stroke()
        let label = NSAttributedString(string: " \(Int(selection.width)) × \(Int(selection.height)) ", attributes: attributes)
        let size = label.size()
        var at = CGPoint(x: selection.minX, y: selection.maxY + 6)
        if at.y + size.height > bounds.maxY { at.y = selection.maxY - size.height - 6 }
        NSColor.black.withAlphaComponent(0.7).setFill()
        CGRect(origin: at, size: size).fill()
        label.draw(at: at)
    }
}

/// A click-through frame drawn just outside the chosen area, so you can see
/// what will be recorded. CaptureDesktop's windows are excluded from capture, so
/// it never appears in the video.
@MainActor
final class AreaOutline {
    static let shared = AreaOutline()
    private var window: NSWindow?
    private let thickness: CGFloat = 3

    func show(_ area: ScreenArea) {
        guard let frame = area.appKitFrame else { return hide() }
        let outer = frame.insetBy(dx: -thickness, dy: -thickness)
        let window = self.window ?? makeWindow()
        self.window = window
        window.setFrame(outer, display: true)
        window.contentView?.needsDisplay = true
        window.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = OutlineView()
        view.thickness = thickness
        window.contentView = view
        CursorLogger.registerPassThroughWindow(window.windowNumber)
        return window
    }
}

private final class OutlineView: NSView {
    var thickness: CGFloat = 3

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: thickness / 2, dy: thickness / 2))
        path.lineWidth = thickness
        path.stroke()
    }
}
