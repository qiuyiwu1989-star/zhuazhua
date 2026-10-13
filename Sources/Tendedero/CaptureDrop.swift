import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class CaptureImport: ObservableObject {
    static let shared = CaptureImport()
    @Published var message = "＋ 拖入图片"
    var onImported: ((URL) -> Void)?
    func accept(_ data: Data) {
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
        } catch { message = "导入失败，请重试" }
    }
    func file(_ url: URL) {
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
        message = "未收到图片内容：请先复制图片，再点这里粘贴"
        return false
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
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .tiff, .png, .URL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        CaptureImport.shared.message = "松开，收进爪爪"; return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { CaptureImport.shared.message = "＋ 拖入图片" }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { CaptureImport.shared.paste(sender.draggingPasteboard) }
    override func mouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let paste = NSMenuItem(title: "粘贴剪贴板图片", action: #selector(pasteImage), keyEquivalent: "")
        paste.target = self; menu.addItem(paste)
        let choose = NSMenuItem(title: "选择图片文件…", action: #selector(chooseImage), keyEquivalent: "")
        choose.target = self; menu.addItem(choose)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func pasteImage() { _ = CaptureImport.shared.paste(.general) }
    @objc private func chooseImage() { CaptureImport.shared.choose() }
}
