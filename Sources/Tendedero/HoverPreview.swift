import AppKit
import ImageIO

/// A read-only, nonactivating enlargement. It never intercepts the card's clicks.
@MainActor
final class HoverPreview {
    static let shared = HoverPreview()
    private var identity: UUID?
    private var since = Date()
    private var shown = false
    private var panel: NSPanel?

    func hide() {
        identity = nil
        shown = false
        panel?.orderOut(nil)
    }

    func update(_ item: Pegged?, below strip: NSRect, on screen: NSScreen?) {
        guard let item, !item.isRecording, !item.falling, !item.flying,
              NSEvent.pressedMouseButtons == 0, !GrabView.isShowingMenu,
              let screen else { hide(); return }
        if identity != item.id {
            hide()
            identity = item.id
            since = Date()
        }
        guard !shown, Date().timeIntervalSince(since) >= 0.4 else { return }
        shown = true
        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1800
              ] as CFDictionary) else { return }
        let visible = screen.visibleFrame.insetBy(dx: 16, dy: 16)
        let top = min(strip.minY - 10, visible.maxY)
        let maxHeight = min(600, top - visible.minY)
        guard maxHeight > 80 else { return }
        let scale = min(min(820, visible.width) / CGFloat(cg.width), maxHeight / CGFloat(cg.height))
        let size = NSSize(width: CGFloat(cg.width) * scale, height: CGFloat(cg.height) * scale)
        let x = min(max(NSEvent.mouseLocation.x - size.width / 2, visible.minX), visible.maxX - size.width)
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.ignoresMouseEvents = true
            p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 2)
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            panel = p
        }
        let image = NSImageView(frame: NSRect(origin: .zero, size: size))
        image.image = NSImage(cgImage: cg, size: .zero)
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        image.layer?.cornerRadius = 10
        image.layer?.masksToBounds = true
        image.setAccessibilityLabel("悬停放大预览")
        panel?.contentView = image
        panel?.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        panel?.orderFrontRegardless()
    }
}
