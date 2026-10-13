import AppKit

/// A transparent strip along the top of the screen that floats over every
/// app and every Space including full screen ones, never takes focus, and lets clicks pass through
/// everywhere except over the photos.
final class LinePanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Float above full-screen content, while leaving system menus above us.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        // Every Space, full screen ones included. Whether the line comes down
        // over a full screen app is up to the user, see FullScreen.showLineOver.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        contentView = content
    }

    /// Two-finger swipes and the scroll wheel, for moving along a long line.
    var onScroll: ((NSEvent) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, let onScroll {
            onScroll(event)
        } else {
            super.sendEvent(event)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The line hangs on the screen you are using, which is the one with the
    /// pointer: that is where you just took the screenshot.
    static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    func placeOnScreen(_ screen: NSScreen? = nil) {
        guard let screen = screen ?? LinePanel.screenUnderPointer() else { return }
        let topInset = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        let top = min(screen.visibleFrame.maxY, screen.frame.maxY - topInset)
        let target = NSRect(x: screen.frame.minX, y: top - Layout.panelHeight,
                            width: screen.frame.width, height: Layout.panelHeight)
        if frame != target { setFrame(target, display: true) }
    }
}
