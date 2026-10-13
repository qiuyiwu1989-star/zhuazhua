import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class CaptureImport: ObservableObject {
    static let shared = CaptureImport()
    @Published var message = "＋ 拖入图片"
    var onImported: ((URL) -> Void)?
    func accept(_ data: Data, uploadImmediately: Bool = false) {
        guard data.count <= 64 * 1024 * 1024, let image = NSImage(data: data),
              let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]), png.count <= 64 * 1024 * 1024 else {
            message = "请选择 64 MB 以内的图片"; return
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        do {
            try png.write(to: temporary, options: .atomic)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let model = WebsiteCapture.shared
            let count = model.records.count
            guard let id = model.stage(temporary), let record = model.records.first(where: { $0.id == id }) else { message = model.message; return }
            onImported?(URL(fileURLWithPath: record.file))
            message = model.records.count == count ? "图片已在爪爪中" : "已收集 · 正在识别文字"
            if uploadImmediately {
                if record.vaultSyncedAt != nil { message = "这张图片已入档" }
                else {
                    message = "已收集 · 正在上传"
                    VaultSync.shared.enqueue([id], model: model) { [weak self] success in
                        self?.message = success ? "已上传到知行档案" : "上传失败 · 已保留本地，可双击重试"
                    }
                }
            }
        } catch { message = "导入失败，请重试" }
    }
    func file(_ url: URL) {
        if ["md", "txt", "markdown"].contains(url.pathExtension.lowercased()) { Notes.shared.importFile(url); return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 64 * 1024 * 1024, let data = try? Data(contentsOf: url) else { message = "无法读取图片，或图片超过 64 MB"; return }
        accept(data)
    }
    func paste(_ board: NSPasteboard) -> Bool {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for url in urls { file(url) }; return true
        }
        if let image = NSImage(pasteboard: board), let data = image.tiffRepresentation { accept(data); return true }
        if let text = board.string(forType: .string), !text.isEmpty { Notes.shared.create(text); return true }
        message = "剪贴板没有可导入的图片或文字"
        return false
    }
    /// Explicit image-only shortcut: text must never become a note on double-click.
    func uploadClipboardImage(_ board: NSPasteboard = .general) {
        guard let image = NSImage(pasteboard: board), let data = image.tiffRepresentation else {
            message = "剪贴板没有图片，请先复制图片"; return
        }
        accept(data, uploadImmediately: true)
    }
    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
        panel.begin { response in
            if response == .OK { for url in panel.urls { self.file(url) } }
        }
    }
}

struct CaptureDrop: NSViewRepresentable {
    func makeNSView(context: Context) -> DropView { DropView() }
    func updateNSView(_ nsView: DropView, context: Context) {}
}
final class DropView: NSView {
    private static var pendingMenu: DispatchWorkItem?
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .tiff, .png, .URL, .string])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        CaptureImport.shared.message = "松开，收进爪爪"; return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { CaptureImport.shared.message = "＋ 拖入图片" }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { CaptureImport.shared.paste(sender.draggingPasteboard) }
    override func mouseDown(with event: NSEvent) {
        Self.pendingMenu?.cancel()
        Self.pendingMenu = nil
        if event.clickCount == 2 {
            CaptureImport.shared.uploadClipboardImage()
            return
        }
        guard event.clickCount <= 1 else { return }
        // Wait for the system double-click interval before opening a tracking menu.
        // Otherwise the first click's menu consumes the second click.
        guard let anchor = window?.contentView else { return }
        let point = anchor.convert(event.locationInWindow, from: nil)
        let work = DispatchWorkItem { [self, anchor] in
            Self.pendingMenu = nil
            self.showMenu(at: point, in: anchor)
        }
        Self.pendingMenu = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }
    private func showMenu(at point: NSPoint, in anchor: NSView) {
        let menu = NSMenu()
        for (title, action) in [("新建图文笔记", #selector(newNote)), ("粘贴文字", #selector(pasteText)), ("导入 Markdown / TXT…", #selector(importText)), ("打开我的笔记", #selector(openNotes))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        let paste = NSMenuItem(title: "粘贴剪贴板图片", action: #selector(pasteImage), keyEquivalent: "")
        paste.target = self; menu.addItem(paste)
        let choose = NSMenuItem(title: "选择图片文件…", action: #selector(chooseImage), keyEquivalent: "")
        choose.target = self; menu.addItem(choose)
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: point, in: anchor)
    }
    @objc private func newNote() { Notes.shared.create() }
    @objc private func pasteText() { Notes.shared.pasteText() }
    @objc private func importText() { Notes.shared.choose() }
    @objc private func openNotes() { Notes.shared.show() }
    @objc private func pasteImage() { _ = CaptureImport.shared.paste(.general) }
    @objc private func chooseImage() { CaptureImport.shared.choose() }
}
