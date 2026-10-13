import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

struct TextNote: Codable, Identifiable, Equatable {
    var id = UUID().uuidString.lowercased()
    var title = ""
    var deletedAt: Date? = nil
    var automaticTitle: Bool? = nil
    var markdown = ""
    var tags = ""
    var sourceURL = ""
    var collectedAt = Date()
    var modifiedAt = Date()
    var attachments: [String] = []
    var version = 0
    var wantsSync = false
    var syncedAt: Date?
    var error: String?
}

@MainActor
final class Notes: ObservableObject {
    static let shared = Notes()
    @Published var records: [TextNote] = []
    @Published var selected: String?
    @Published var message = "草稿自动保存在本机；保存并同步后进入知行档案"
    @Published var busy = false
    @Published var search = ""
    @Published var showingTrash = false
    private var readable = true
    private var window: NSWindow?
    private let ledger: URL
    private var attachmentDirectory: URL { ledger.deletingLastPathComponent().appendingPathComponent("note-attachments", isDirectory: true) }
    static func localAttachment(_ digest: String) -> URL { WebsiteCapture.directory.appendingPathComponent("note-attachments", isDirectory: true).appendingPathComponent(digest + ".png") }
    private let credentialURL: URL
    private let telemetryEnabled: Bool
    private var pending = Set<String>()
    private var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 90
        c.httpCookieStorage = nil
        return URLSession(configuration: c, delegate: CaptureRedirects(), delegateQueue: nil)
    }()
    init(directory: URL = WebsiteCapture.directory, credentialURL: URL? = nil, session: URLSession? = nil, telemetryEnabled: Bool = true) {
        self.telemetryEnabled = telemetryEnabled
        self.credentialURL = credentialURL ?? VaultSync.tokenURL
        if let session { self.session = session }
        ledger = directory.appendingPathComponent("notes.json")
        if FileManager.default.fileExists(atPath: ledger.path) {
            do { records = try JSONDecoder().decode([TextNote].self, from: Data(contentsOf: ledger)) }
            catch { readable = false; message = "笔记记录读取失败，已停止写入以保护原文件" }
        }
        var changed = false
        for i in records.indices where records[i].title.isEmpty && !records[i].markdown.isEmpty {
            records[i].title = Self.suggestTitle(records[i].markdown)
            records[i].automaticTitle = true
            records[i].syncedAt = nil
            records[i].wantsSync = false
            changed = true
        }
        if changed { _ = persist() }
    }
    static func suggestTitle(_ markdown: String) -> String {
        let blocks = NoteBlock.parse(markdown)
        let heading = blocks.first { if case .heading = $0.kind { return true }; return false }
        let first = heading ?? blocks.first { $0.kind == .paragraph || $0.kind == .quote }
        guard let text = first?.text else { return "" }
        let plain = String(MarkdownNotePreview.inline(text).characters).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(plain.prefix(36)) + (plain.count > 36 ? "…" : "")
    }
    @discardableResult func persist() -> Bool {
        guard readable else { return false }
        do {
            try FileManager.default.createDirectory(at: ledger.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: ledger, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledger.path)
            return true
        } catch { message = "本地保存失败：" + error.localizedDescription; return false }
    }
    func create(_ text: String = "", title: String = "") {
        guard readable, text.utf8.count <= 1024 * 1024 else { message = "文字不能超过 1 MB"; return }
        var n = TextNote(); n.markdown = text; n.title = title.isEmpty ? Self.suggestTitle(text) : title; n.automaticTitle = title.isEmpty
        n.attachments = Self.attachmentDigests(text)
        if let error = Self.validationError(n) { message = error; show(); return }
        records.insert(n, at: 0); selected = n.id
        _ = persist(); show(); recordEvent("note_editor_opened")
    }
    func setTrashed(_ id: String, trashed: Bool) {
        guard !busy, let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].deletedAt = trashed ? Date() : nil
        records[i].wantsSync = false
        pending.remove(id)
        if persist() { selected = nil; message = trashed ? "已移入本机回收站，可恢复；云端已有副本保留" : "笔记已恢复" }
    }
    static func clipboardSource(_ board: NSPasteboard) -> String {
        // Only trust explicit clipboard metadata, never the current foreground tab.
        let html = board.string(forType: .html) ?? ""
        let candidates = [board.string(forType: NSPasteboard.PasteboardType("org.chromium.source-url")),
                          html.components(separatedBy: "\n").first(where: { $0.hasPrefix("SourceURL:") }).map { String($0.dropFirst(10)).trimmingCharacters(in: .whitespacesAndNewlines) }]
        return candidates.compactMap { $0 }.first { value in
            guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return false }
            return true
        } ?? ""
    }
    func duplicate(_ original: TextNote) {
        guard readable else { return }
        var note = original
        note.id = UUID().uuidString.lowercased(); note.collectedAt = Date(); note.modifiedAt = Date()
        note.version = 0; note.syncedAt = nil; note.wantsSync = false; note.error = nil
        records.insert(note, at: 0); selected = note.id; _ = persist()
    }
    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "爪爪 · 图文笔记"; w.minSize = NSSize(width: 800, height: 500)
            w.contentView = NSHostingView(rootView: NotesView(model: self)); w.isReleasedWhenClosed = false
            w.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]; w.center(); window = w
        }
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    func edit(_ value: TextNote) {
        guard let i = records.firstIndex(where: { $0.id == value.id }) else { return }
        var n = value; n.modifiedAt = Date(); n.syncedAt = nil; n.error = nil; n.wantsSync = false
        if value.title != records[i].title { n.automaticTitle = value.title.isEmpty }
        if n.automaticTitle == true || n.title.isEmpty {
            n.title = Self.suggestTitle(n.markdown); n.automaticTitle = true
        }
        n.attachments = Self.attachmentDigests(n.markdown)
        records[i] = n
        if persist() { message = "草稿已保存到本机" }
    }
    func importFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1024 * 1024,
              let text = try? String(contentsOf: url, encoding: .utf8) else { message = "请选择 1 MB 以内的 UTF-8 文字文件"; show(); return }
        create(text, title: String(url.deletingPathExtension().lastPathComponent.prefix(512))); recordEvent("note_imported")
        if text.contains("![") { message = "文字已导入。文件中的相对路径或远程图片不会自动复制；请通过插入图片重新添加附件。" }
    }
    func choose() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]; panel.allowsMultipleSelection = true
        panel.begin { result in if result == .OK { for url in panel.urls { self.importFile(url) } } }
    }
    func pasteText() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { message = "剪贴板没有文字"; show(); return }
        create(text)
        if let id = selected, var note = records.first(where: { $0.id == id }) {
            note.sourceURL = Self.clipboardSource(.general)
            edit(note)
            if note.sourceURL.isEmpty { message = "文字已保存；剪贴板未附带来源，请在来源链接中填写原页面地址" }
        }
    }
    func addImage(id: String) {
        guard let image = NSImage(pasteboard: .general), let tiff = image.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff), let data = bmp.representation(using: .png, properties: [:]), data.count <= 64 * 1024 * 1024 else { message = "请先复制一张图片"; return }
        attachImageData(data, id: id)
    }
    func attachImageData(_ data: Data, id: String) {
        guard data.count <= 64 * 1024 * 1024, let image = NSImage(data: data),
              let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]), png.count <= 64 * 1024 * 1024 else { message = "请选择 64 MB 以内的图片"; return }
        do {
            guard var note = records.first(where: { $0.id == id }) else { return }
            let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            note.markdown += "\n\n![图片](/api/zhuazhua/image/\(digest))\n"
            if let error = Self.validationError(note) { message = error; return }
            try FileManager.default.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let local = attachmentDirectory.appendingPathComponent(digest + ".png")
            try png.write(to: local, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: local.path)
            edit(note)
        } catch { message = "图片保存失败，文字草稿保留" }
    }

    func dropImages(_ providers: [NSItemProvider], id: String) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    Task { @MainActor in
                        guard let url, url.isFileURL else { self.message = "无法读取拖入的图片"; return }
                        let scope = url.startAccessingSecurityScopedResource(); defer { if scope { url.stopAccessingSecurityScopedResource() } }
                        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 * 1024 * 1024,
                              let data = try? Data(contentsOf: url) else { self.message = "无法读取图片，或图片超过 64 MB"; return }
                        self.attachImageData(data, id: id)
                    }
                }
            } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                accepted = true
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    Task { @MainActor in
                        guard let data else { self.message = "无法读取拖入的图片"; return }
                        self.attachImageData(data, id: id)
                    }
                }
            }
        }
        return accepted
    }
    func enqueue(_ ids: [String]) {
        for i in records.indices where ids.contains(records[i].id) && records[i].deletedAt == nil { records[i].wantsSync = true }
        guard persist() else { return }
        pending.formUnion(ids.filter { id in records.contains { $0.id == id && $0.deletedAt == nil } }); guard !busy else { return }; busy = true
        Task {
            while let id = pending.first { pending.remove(id); await sync(id) }
            busy = false
        }
    }
    static func validationError(_ note: TextNote) -> String? {
        if note.title.unicodeScalars.count > 512 { return "标题最多 512 个字符" }
        if note.tags.unicodeScalars.count > 4000 { return "标签最多 4000 个字符" }
        if note.sourceURL.unicodeScalars.count > 2048 { return "来源链接最多 2048 个字符" }
        if note.markdown.unicodeScalars.count > 500000 || note.markdown.utf8.count > 1024 * 1024 { return "正文最多 500000 个字符、1 MB" }
        return nil
    }
    static func attachmentDigests(_ markdown: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\(/api/zhuazhua/image/([a-f0-9]{64})\)"#) else { return [] }
        let ns = markdown as NSString
        var result: [String] = []
        for match in regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
            let digest = ns.substring(with: match.range(at: 1))
            if !result.contains(digest) { result.append(digest) }
        }
        return result
    }
    private func recordEvent(_ name: String, outcome: String = "success", durationMs: Int = 0, errorCode: String = "none") {
        if telemetryEnabled { NoteEvents.shared.record(name, outcome: outcome, durationMs: durationMs, errorCode: errorCode) }
    }
    func retryPending() { if VaultSync.shared.automatic { enqueue(records.filter { $0.wantsSync && $0.syncedAt == nil && !$0.markdown.isEmpty }.map(\.id)) } }
    func sync(_ id: String) async {
        guard let note = records.first(where: { $0.id == id && $0.deletedAt == nil }), !note.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, persist() else { return }
        let started = Date(); var errorCode = "unknown"
        do {
            if let validation = Self.validationError(note) { errorCode = "validation"; throw CaptureFailure(message: validation) }
            for digest in note.attachments {
                let record = WebsiteCapture.shared.records.first(where: { $0.id == digest })
                if record?.vaultSyncedAt != nil { continue }
                let local = attachmentDirectory.appendingPathComponent(digest + ".png")
                let file = FileManager.default.fileExists(atPath: local.path) ? local : record.map { URL(fileURLWithPath: $0.file) }
                guard let file else { throw CaptureFailure(message: "本地附件缺失，请重新插入图片") }
                try await VaultSync.shared.syncAttachment(digest, file: file)
            }
            let token = try String(contentsOf: credentialURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw CaptureFailure(message: "尚未连接知行档案设备") }
            let f = ISO8601DateFormatter()
            let payload: [String: Any] = ["id":note.id,"title":note.title,"markdown":note.markdown,"tags":note.tags,"sourceURL":note.sourceURL,"collectedAt":f.string(from:note.collectedAt),"modifiedAt":f.string(from:note.modifiedAt),"attachments":note.attachments,"version":note.version]
            var req = URLRequest(url: URL(string:"https://qiuyiwu.com/api/zhuazhua/notes")!); req.httpMethod = "POST"
            req.setValue("Bearer " + token, forHTTPHeaderField:"Authorization"); req.setValue("application/json", forHTTPHeaderField:"Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            message = "正在同步笔记…"
            let (data, response) = try await session.data(for:req)
            let json = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
            if (response as? HTTPURLResponse)?.statusCode == 409 { errorCode = "conflict"; throw CaptureFailure(message:"网站已有其他版本；本地草稿保留。请在网站核对，或复制为新笔记后同步") }
            guard (response as? HTTPURLResponse)?.statusCode == 200, json?["ok"] as? Bool == true,
                  let result = json?["note"] as? [String:Any], result["id"] as? String == note.id, let version = result["version"] as? Int, version > 0 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                errorCode = status == 401 ? "unauthorized" : status == 400 ? "validation" : "unknown"
                throw CaptureFailure(message: json?["error"] as? String ?? "同步未完成，请检查连接后重试")
            }
            if let i = records.firstIndex(where: {$0.id == id}) {
                records[i].version = version; records[i].syncedAt = records[i].modifiedAt == note.modifiedAt ? Date() : nil; records[i].error = nil
                if records[i].syncedAt != nil { records[i].wantsSync = false }
                guard persist() else {
                    records[i].syncedAt = nil; records[i].wantsSync = true
                    records[i].error = "云端已接收，但本地同步状态写入失败，请重试"
                    message = records[i].error!; return
                }
                message = records[i].syncedAt == nil ? "已有新修改留在本机，请再次保存并同步" : "已同步到知行档案收件箱"
            }
            recordEvent("note_sync_completed", durationMs: Int(Date().timeIntervalSince(started) * 1000))
        } catch {
            if let i = records.firstIndex(where: {$0.id == id}) { records[i].error = error.localizedDescription; _ = persist() }
            message = "同步失败，草稿保留：" + error.localizedDescription; recordEvent("note_sync_failed", outcome: "failure", durationMs: Int(Date().timeIntervalSince(started) * 1000), errorCode: (error as NSError).domain == NSURLErrorDomain ? "network" : errorCode)
        }
    }
}

struct NotesView: View {
    @ObservedObject var model: Notes
    var body: some View {
        HStack(spacing: 0) {
            VStack {
                HStack { Button("新建") { model.create() }; Button("导入") { model.choose() } }
                TextField("搜索本地笔记", text: $model.search)
                    .task(id: model.search) {
                        let start = Date()
                        try? await Task.sleep(for: .milliseconds(450))
                        guard !Task.isCancelled, !model.search.isEmpty else { return }
                        let count = model.records.filter { ($0.title + $0.markdown + $0.tags).localizedCaseInsensitiveContains(model.search) }.count
                        NoteEvents.shared.record("search_completed", durationMs: Int(Date().timeIntervalSince(start) * 1000), count: count)
                    }
                List(selection: $model.selected) {
                    ForEach(model.records.filter { ($0.deletedAt != nil) == model.showingTrash && (model.search.isEmpty || ($0.title + $0.markdown + $0.tags).localizedCaseInsensitiveContains(model.search)) }) { n in
                        VStack(alignment: .leading) { Text(n.title.isEmpty ? "未命名笔记" : n.title).lineLimit(1); Text(n.syncedAt == nil ? "本地草稿" : "已入档").font(.caption).foregroundStyle(.secondary) }.tag(n.id)
                            .contextMenu { Button(model.showingTrash ? "恢复笔记" : "移入本机回收站") { model.setTrashed(n.id, trashed: !model.showingTrash) }.disabled(model.busy) }
                    }
                }
                Toggle("本机回收站", isOn: $model.showingTrash).onChange(of: model.showingTrash) { _, _ in model.selected = nil }
                Button("重试未同步笔记") { model.enqueue(model.records.filter {$0.wantsSync && $0.syncedAt == nil}.map(\.id)) }.disabled(model.busy)
            }.padding(12).frame(width: 180)
            Divider()
            if let id = model.selected, let n = model.records.first(where: {$0.id == id}) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("笔记标题（可选）", text: field(n, \.title)).font(.title2)
                    HStack { TextField("标签", text: field(n, \.tags)); TextField("来源链接（可选）", text: field(n, \.sourceURL)) }
                    HStack {
                        Button("插入剪贴板图片") { model.addImage(id:id) }
                        Button("复制为新笔记") { model.duplicate(n) }
                        Button(n.deletedAt == nil ? "移入回收站" : "恢复笔记") { model.setTrashed(id, trashed: n.deletedAt == nil) }.disabled(model.busy)
                        Spacer()
                        Button(model.busy ? "同步中…" : "保存并同步") { model.enqueue([id]) }.disabled(model.busy || n.markdown.isEmpty || n.deletedAt != nil).keyboardShortcut("s", modifiers:.command)
                    }
                    HSplitView {
                        VStack(alignment:.leading) { Text("Markdown 原文").font(.caption); TextEditor(text:field(n, \.markdown)).font(.system(.body,design:.monospaced)) }.frame(minWidth:230)
                        VStack(alignment:.leading) { Text("预览 · 可拖入图片").font(.caption); MarkdownNotePreview(markdown:n.markdown).onDrop(of: [UTType.image, UTType.fileURL], isTargeted: nil) { providers in model.dropImages(providers, id: id) } }.frame(minWidth:230)
                    }
                    Text(model.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding(18)
            } else { VStack { Text("把文字也收进爪爪").font(.title2); Button("新建图文笔记") { model.create() }; Button("粘贴剪贴板文字") { model.pasteText() } }.frame(maxWidth:.infinity,maxHeight:.infinity) }
        }
    }
    private func field(_ note: TextNote, _ key: WritableKeyPath<TextNote,String>) -> Binding<String> {
        Binding(get: { model.records.first(where: {$0.id == note.id})?[keyPath:key] ?? "" }, set: { value in
            guard var current = model.records.first(where: {$0.id == note.id}) else { return }
            current[keyPath:key] = value
            if let error = Notes.validationError(current) { model.message = error; return }
            model.edit(current)
        })
    }
}

/// A deliberately small native Markdown renderer: never executes HTML or fetches remote images.
struct NoteBlock: Identifiable, Equatable {
    enum Kind: Equatable { case paragraph, heading(Int), code, quote, list(String), image(String), rule, table([[String]]) }
    var id: Int
    var kind: Kind
    var text: String
    static func parse(_ source: String) -> [NoteBlock] {
        var blocks: [NoteBlock] = []; var code: [String] = []; var fence: String?
        func add(_ kind: Kind, _ text: String) { blocks.append(NoteBlock(id: blocks.count, kind: kind, text: text)) }
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]; index += 1
            if fence == nil, index < lines.count, line.contains("|"), Self.isTableDivider(lines[index]) {
                let header = Self.cells(line)
                if header.count == Self.cells(lines[index]).count {
                    var rows = [header]; index += 1
                    while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                        let cells = Self.cells(lines[index]); rows.append(Array((cells + Array(repeating: "", count: header.count)).prefix(header.count))); index += 1
                    }
                    add(.table(rows), ""); continue
                }
            }
            if let marker = fence {
                if line.hasPrefix(marker) { add(.code, code.joined(separator: "\n")); code = []; fence = nil }
                else { code.append(line) }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fence = String(line.prefix(3)); continue }
            if let digest = MarkdownNotePreview.imageDigest(line), line.trimmingCharacters(in: .whitespaces).hasPrefix("![") { add(.image(digest), line); continue }
            if ["---", "***", "___"].contains(line.trimmingCharacters(in: .whitespaces)) { add(.rule, ""); continue }
            let hashes = line.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") { add(.heading(hashes), String(line.dropFirst(hashes + 1))); continue }
            if line.hasPrefix("> ") { add(.quote, String(line.dropFirst(2))); continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") { add(.list("•"), String(trimmed.dropFirst(2))); continue }
            let numbers = trimmed.prefix(while: { $0.isNumber })
            if !numbers.isEmpty, trimmed.dropFirst(numbers.count).hasPrefix(". ") { add(.list(String(numbers) + "."), String(trimmed.dropFirst(numbers.count + 2))); continue }
            if !line.isEmpty { add(.paragraph, line) }
        }
        if fence != nil { add(.code, code.joined(separator: "\n")) }
        return blocks
    }
    static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }; if text.hasSuffix("|") { text.removeLast() }
        var result: [String] = [], cell = "", escaped = false, inCode = false
        for ch in text {
            if escaped { cell.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "`" { inCode.toggle() }
            if ch == "|" && !inCode { result.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" } else { cell.append(ch) }
        }
        if escaped { cell.append("\\") }
        result.append(cell.trimmingCharacters(in: .whitespaces)); return result
    }
    static func isTableDivider(_ line: String) -> Bool {
        let parts = cells(line)
        return line.contains("|") && parts.allSatisfy { $0.range(of: "^:?-{3,}:?$", options: .regularExpression) != nil }
    }
}
struct MarkdownNotePreview: View {
    let markdown: String
    var body: some View {
        ScrollView {
            LazyVStack(alignment:.leading,spacing:18) {
                ForEach(NoteBlock.parse(markdown)) { block in
                    switch block.kind {
                    case .heading(let depth):
                        Text(Self.inline(block.text)).font(.system(size: depth == 1 ? 28 : depth == 2 ? 23 : 19, weight: .semibold)).padding(.top, 12).textSelection(.enabled)
                    case .code:
                        Text(block.text).font(.system(.body,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(10).background(.quaternary,in:RoundedRectangle(cornerRadius:6))
                    case .quote:
                        HStack(alignment:.top) { Rectangle().fill(.secondary).frame(width:3); Text(Self.inline(block.text)).italic().textSelection(.enabled) }.fixedSize(horizontal:false,vertical:true)
                    case .list(let marker):
                        HStack(alignment:.top) { Text(marker).frame(minWidth:18,alignment:.trailing); Text(Self.inline(block.text)).textSelection(.enabled) }
                    case .image(let digest):
                        if let image = Self.localImage(digest) {
                            Image(nsImage:image).resizable().scaledToFit()
                        } else { Label("本机没有这张附件图片",systemImage:"photo").foregroundStyle(.secondary) }
                    case .table(let rows):
                        ScrollView(.horizontal) {
                            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                                ForEach(rows.indices, id: \.self) { row in
                                    GridRow {
                                        ForEach(rows[row].indices, id: \.self) { column in
                                            Text(Self.inline(rows[row][column]))
                                                .font(.system(size: 14, weight: row == 0 ? .semibold : .regular))
                                                .lineSpacing(5).textSelection(.enabled)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .frame(width: rows[row].count <= 2 ? 230 : 180, alignment: .topLeading)
                                                .padding(12)
                                                .frame(maxHeight: .infinity, alignment: .topLeading)
                                                .background(row == 0 ? Color.accentColor.opacity(0.09) : row.isMultiple(of: 2) ? Color.primary.opacity(0.025) : Color.clear)
                                                .overlay(Rectangle().stroke(Color.primary.opacity(0.09), lineWidth: 0.5))
                                        }
                                    }
                                }
                            }.clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    case .rule: Divider().padding(.vertical, 6)
                    case .paragraph: Text(Self.inline(block.text)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                    }
                }
            }.font(.system(size: 16)).lineSpacing(7).padding(28).frame(maxWidth: 860, alignment: .leading).frame(maxWidth:.infinity,alignment:.center)
        }.background(Color(nsColor:.textBackgroundColor))
    }
    static func localImage(_ digest: String) -> NSImage? {
        if let image = NSImage(contentsOf: Notes.localAttachment(digest)) { return image }
        return WebsiteCapture.shared.records.first(where: { $0.id == digest }).flatMap { NSImage(contentsOfFile: $0.file) }
    }
    static func imageDigest(_ text:String) -> String? {
        guard let range = text.range(of:"/api/zhuazhua/image/"), let end = text[range.upperBound...].firstIndex(of:")") else { return nil }
        let value = String(text[range.upperBound..<end]); return value.count == 64 && value.allSatisfy({$0.isHexDigit}) ? value : nil
    }
    static func inline(_ text:String) -> AttributedString {
        // Accept pasted strong spans with whitespace next to their delimiters.
        // Tokenize code and escaped characters first so their asterisks stay literal.
        let pattern = #"(`+)[\s\S]*?\1|\\.|(?<!\*)\*\*(?!\*)([^\n]*?\S[ \t]*)\*\*(?!\*)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let source = text as NSString
        var result = AttributedString()
        var cursor = 0
        func parsed(_ value: String) -> AttributedString {
            (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
        }
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result.append(parsed(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
            if match.range(at: 2).location != NSNotFound {
                var strong = parsed(source.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces))
                for run in strong.runs {
                    var intent = run.inlinePresentationIntent ?? []
                    intent.insert(.stronglyEmphasized)
                    strong[run.range].inlinePresentationIntent = intent
                }
                result.append(strong)
            } else {
                result.append(parsed(source.substring(with: match.range)))
            }
            cursor = NSMaxRange(match.range)
        }
        result.append(parsed(source.substring(from: cursor)))
        for run in result.runs { if run.link != nil { result[run.range].link = nil } }
        return result
    }
}

@MainActor
final class NoteEvents: ObservableObject {
    static let shared = NoteEvents()
    @Published var enabled = UserDefaults.standard.bool(forKey:"experienceMetrics") { didSet { UserDefaults.standard.set(enabled,forKey:"experienceMetrics") } }
    private let allowed: Set<String> = ["note_editor_opened","note_imported","note_sync_completed","note_sync_failed","search_completed"]
    private let session = URLSession(configuration: .ephemeral, delegate: CaptureRedirects(), delegateQueue: nil)
    func record(_ name:String, outcome: String = "success", durationMs: Int = 0, count: Int = 1, errorCode: String = "none") {
        guard enabled, allowed.contains(name), ["success", "failure", "cancelled"].contains(outcome) else { return }
        // Strict, content-free event schema: never include note IDs, content, paths, URLs or search text.
        Task {
            guard enabled, let token = try? String(contentsOf: VaultSync.tokenURL, encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines), !token.isEmpty else { return }
            var request = URLRequest(url:URL(string:"https://qiuyiwu.com/api/zhuazhua/events")!)
            request.httpMethod = "POST"; request.timeoutInterval = 8
            request.setValue("Bearer " + token, forHTTPHeaderField:"Authorization")
            request.setValue("application/json", forHTTPHeaderField:"Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject:["event":name,"source":"desktop","outcome":outcome,"count":max(0,min(count,1000)),"durationMs":max(0,min(durationMs,600000)),"errorCode":["none","network","validation","conflict","unauthorized","unknown"].contains(errorCode) ? errorCode : "unknown"])
            // Best effort, no local queue, no retries: telemetry must not block saving notes.
            _ = try? await session.data(for:request)
        }
    }
}
