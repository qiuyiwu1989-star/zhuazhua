import AppKit
import SwiftUI
import ImageIO

private final class WaterfallPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class CaptureWaterfall {
    static let shared = CaptureWaterfall()
    private var panel: NSPanel?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    func show() {
        guard let screen = LinePanel.screenUnderPointer() else { return }
        if panel == nil {
            let p = WaterfallPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            p.title = "爪爪 · 全部采集"
            p.isReleasedWhenClosed = false
            p.level = .floating
            p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            p.backgroundColor = .windowBackgroundColor
            p.contentView = NSHostingView(rootView: CaptureDrawerView())
            panel = p
        }
        let area = screen.visibleFrame
        let height = max(240, area.height - Layout.panelHeight)
        panel?.setFrame(NSRect(x: area.minX + 12, y: area.minY + 12, width: area.width - 24, height: height - 12), display: true)
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        installOutsideClickMonitors()
    }
    func hide() {
        panel?.orderOut(nil)
        if let monitor = localClickMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = globalClickMonitor { NSEvent.removeMonitor(monitor) }
        localClickMonitor = nil
        globalClickMonitor = nil
    }
    private func installOutsideClickMonitors() {
        guard localClickMonitor == nil else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return event }
            if panel.attachedSheet == nil, let target = event.window, target !== panel, target.parent !== panel { self.hide() }
            return event // Preserve the clicked control's original action.
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            if panel.attachedSheet == nil && !panel.frame.contains(NSEvent.mouseLocation) { self.hide() }
        }
    }
}
