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
            p.contentView = NSHostingView(rootView: CaptureWaterfallView())
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
            if event.window !== panel && !panel.frame.contains(NSEvent.mouseLocation) { self.hide() }
            return event // Preserve the clicked control's original action.
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            if !panel.frame.contains(NSEvent.mouseLocation) { self.hide() }
        }
    }
}

private struct CaptureWaterfallView: View {
    @ObservedObject private var model = WebsiteCapture.shared
    @State private var query = ""
    @State private var preview: CaptureRecord?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "square.grid.2x2")
                Text("全部采集").font(.headline)
                TextField("搜索图片文字、备注、标签", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                Spacer()
                Button("搜索与整理") { CaptureDrawer.shared.show() }
                Button("收起", systemImage: "chevron.up") { if preview != nil { preview = nil } else { CaptureWaterfall.shared.hide() } }.keyboardShortcut(.escape, modifiers: [])
            }.padding(16)
            Divider()
            GeometryReader { geo in
                let count = max(2, Int(geo.size.width / 250))
                let records = model.records.filter { $0.matchesSearch(query) }.sorted { $0.created > $1.created }
                ScrollView {
                    if records.isEmpty { Text("还没有匹配的图片").padding(40) }
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(0..<count, id: \.self) { column in
                            LazyVStack(spacing: 16) {
                                ForEach(Array(records.enumerated()).filter { $0.offset % count == column }.map(\.element)) { record in
                                    WaterfallImage(record: record, onPreview: { preview = record })
                                }
                            }.frame(maxWidth: .infinity)
                        }
                    }.padding(20)
                }
            }
        }.background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if let record = preview {
                ZStack {
                    Color.black.opacity(0.8).onTapGesture { preview = nil }
                    VStack(spacing: 12) {
                        HStack {
                            Button("返回收藏库", systemImage: "chevron.left") { preview = nil }
                            Spacer()
                            Button("打开原图 ↗") { NSWorkspace.shared.open(URL(fileURLWithPath: record.file)) }
                        }
                        if let image = NSImage(contentsOfFile: record.file) {
                            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else { Text("原图暂时不可读取").frame(maxWidth: .infinity, maxHeight: .infinity) }
                    }.padding(20).background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16)).padding(32)
                }
            }
        }
    }
}

private struct WaterfallImage: View {
    let record: CaptureRecord
    let onPreview: () -> Void
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                    .onTapGesture(perform: onPreview)
                    .help("点击放大预览，保留浏览位置")
            } else { RoundedRectangle(cornerRadius: 12).fill(.quaternary).frame(height: 160) }
        }
        .task(id: record.file) {
            let path = record.file
            let data = await Task.detached(priority: .utility) { () -> Data? in
                guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 640, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
                return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            }.value
            if !Task.isCancelled { image = data.flatMap { NSImage(data: $0) } }
        }
    }
}
