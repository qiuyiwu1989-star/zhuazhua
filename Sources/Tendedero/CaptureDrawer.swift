import AppKit
import SwiftUI

@MainActor
final class CaptureDrawer {
    static let shared = CaptureDrawer()
    var onOpen: (() -> Void)?
    private var window: NSPanel?
    private var expanded = false
    func show() {
        onOpen?()
        CaptureWaterfall.shared.show()
    }

    func hide() { CaptureWaterfall.shared.hide() }
    func toggleSize() { expanded.toggle(); place() }
    private func place() {
        guard let screen = window?.screen ?? LinePanel.screenUnderPointer() else { return }
        let area = screen.visibleFrame
        let height = expanded ? area.height : min(area.height, max(420, area.height * 0.58))
        window?.setFrame(NSRect(x: area.minX + 12, y: area.maxY - height, width: area.width - 24, height: height), display: true, animate: true)
    }
}

struct CaptureDrawerView: View {
    @ObservedObject private var model = WebsiteCapture.shared
    @FocusState private var searchFocused: Bool
    @FocusState private var tagFocused: Bool
    @State private var organizing = false
    @State private var feedback = ""
    @State private var query = ""
    @State private var dateFilter = false
    @State private var day = Date()
    @State private var timeKind = "收集"
    @State private var batchTag = ""
    @State private var undoTags: [String: String] = [:]
    @State private var selected = Set<String>()
    @ObservedObject private var vault = VaultSync.shared
    @State private var preview: CaptureRecord?
    private var matches: [CaptureRecord] {
        model.records.filter { record in
            record.matchesSearch(query) && (!dateFilter || (timeKind == "收集" ? [record.created] : record.organizedAt ?? []).contains { Calendar.current.isDate($0, inSameDayAs: day) })
        }.sorted { a, b in
            (timeKind == "收集" ? a.created : a.organizedAt?.last ?? .distantPast) > (timeKind == "收集" ? b.created : b.organizedAt?.last ?? .distantPast)
        }
    }
    private var hiddenSelection: Set<String> { selected.subtracting(matches.map(\.id)) }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                TextField("搜索图片文字、文件名、备注、标签", text: $query).textFieldStyle(.roundedBorder).focused($searchFocused)
                Text("\(matches.count) 张").foregroundStyle(.secondary)
                Button(organizing ? "完成整理" : "选择与整理", systemImage: "checkmark.circle") { organizing.toggle() }
                Button("收起", systemImage: "chevron.up") { CaptureDrawer.shared.hide() }.keyboardShortcut(.escape, modifiers: [])
            }
            if organizing {
            HStack {
                Toggle("按日期查看", isOn: $dateFilter)
                Picker("时间", selection: $timeKind) { Text("收集时间").tag("收集"); Text("整理时间").tag("整理") }.frame(width: 175)
                DatePicker("日期", selection: $day, displayedComponents: .date).disabled(!dateFilter)
                Button("今天") { day = Date(); dateFilter = true }
                Spacer()
                Text(timeKind == "整理" ? "整理记录从此版本开始；修改备注或标签时记录" : "按首次收进爪爪的时间查看").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(selected.isEmpty ? "双击预览 · 勾选后批量整理" : "已选择 \(selected.count) 张")
                Spacer()
                Button("预览选中") { preview = matches.first { selected.contains($0.id) } }
                    .disabled(!matches.contains { selected.contains($0.id) })
                Button("同步到知行档案") { vault.enqueue(Array(selected), model: model) }
                    .disabled(selected.isEmpty || !hiddenSelection.isEmpty || vault.busy || !vault.connected)
                Button("收件箱 ↗") { vault.openInbox() }
                Button("全选结果") { selected = Set(matches.map(\.id)) }
                Button("取消选择") { selected.removeAll() }.disabled(selected.isEmpty)
                Button("在访达显示") {
                    NSWorkspace.shared.activateFileViewerSelecting(model.records.filter { selected.contains($0.id) }.map { URL(fileURLWithPath: $0.file) })
                }.disabled(selected.isEmpty)
            }.font(.callout)
            if !hiddenSelection.isEmpty {
                HStack {
                    Text("已选中 \(hiddenSelection.count) 张不在当前结果中；请先确定批量操作范围。")
                    Button("仅保留当前结果") { selected.subtract(hiddenSelection) }
                    Button("清除筛选查看选择") { query = ""; dateFilter = false }
                }.font(.callout).foregroundStyle(.orange)
            }
            Text(vault.message).font(.caption).foregroundStyle(.secondary)
            if !feedback.isEmpty { Text(feedback).font(.caption).foregroundStyle(.secondary) }
            if !selected.isEmpty {
                HStack {
                    TextField("为选中图片添加标签", text: $batchTag).textFieldStyle(.roundedBorder).focused($tagFocused)
                    Button("添加标签") {
                        undoTags = [:]
                        for record in model.records where selected.contains(record.id) && record.state != "已保存" && record.state != "正在上传" {
                            if model.edit(record.id, note: record.note, tags: CaptureTags.merge(record.tags, batchTag)) { undoTags[record.id] = record.tags }
                        }
                        feedback = "已处理 \(undoTags.count) 张，跳过 \(selected.count - undoTags.count) 张；可撤销标签。"
                        batchTag = ""
                    }.disabled(!hiddenSelection.isEmpty || batchTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("撤销标签") {
                        for record in model.records { if let tags = undoTags[record.id] { model.edit(record.id, note: record.note, tags: tags) } }
                        undoTags = [:]
                        feedback = "已撤销标签；已上传或正在上传的记录保持不变。"
                    }.disabled(undoTags.isEmpty)
                }
                Text("标签应用于选中的本地图片；已上传或正在上传的记录不会修改。 ").font(.caption).foregroundStyle(.secondary)
            }
            }
            if matches.isEmpty {
                Spacer()
                Text(query.isEmpty ? "截图后，图片会自动收集到这里" : "没有匹配的图片，试试其他关键词").foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(0..<4, id: \.self) { column in
                        LazyVStack(spacing: 16) {
                        ForEach(Array(matches.enumerated()).filter { $0.offset % 4 == column }.map(\.element)) { record in
                            VStack(alignment: .leading, spacing: 6) {
                                if let image = NSImage(contentsOfFile: record.file) {
                                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                                        .contentShape(Rectangle()).onTapGesture { preview = record }
                                }
                                if organizing {
                                Toggle(isOn: Binding(get: { selected.contains(record.id) }, set: { on in
                                    searchFocused = false; tagFocused = false
                                    if on { selected.insert(record.id) } else { selected.remove(record.id) }
                                })) { Text(record.name).lineLimit(1).help(record.name) }
                                HStack {
                                    Text(record.state == "待保存" ? "已收集" : record.state).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("预览") { preview = record }
                                }.font(.caption)
                                if !record.tags.isEmpty { Text(record.tags).font(.caption).foregroundStyle(.teal).lineLimit(2) }
                                Text("收集：" + record.created.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                                if let last = record.organizedAt?.last { Text("整理：" + last.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary) }
                                Text(record.vaultError != nil ? "同步待重试" : (record.vaultSyncedAt != nil ? "已同步到知行档案" : "仅在本地")).font(.caption2).foregroundStyle(.secondary)
                                Text(model.ocrStatus(record)).font(.caption2).foregroundStyle(.secondary)
                                if let excerpt = record.searchExcerpt(query) { Text(excerpt).font(.caption).lineLimit(2).help(excerpt) }
                                }
                            }
                            .padding(organizing ? 10 : 0).background(selected.contains(record.id) ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                            .contextMenu {
                                Button(record.vaultSyncedAt == nil ? "同步到知行档案" : "重新同步到知行档案") { vault.enqueue([record.id], model: model) }
                                if let error = record.vaultError { Text("同步失败：" + error) }
                                Button("重新识别文字") { model.recognize(record.id) }
                                    .disabled(model.recognizing.contains(record.id))
                                Button("查看与编辑备注") { preview = record }
                                Button("复制图片") {
                                    if let image = NSImage(contentsOfFile: record.file) { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image]) }
                                }
                            }
                        }
                        }.frame(maxWidth: .infinity)
                        }
                    }.padding(4)
                }
            }
        }
        .padding(16).frame(minWidth: 640, minHeight: 320)
        .onKeyPress(.space) {
            guard !searchFocused, !tagFocused, preview == nil, let first = matches.first(where: { selected.contains($0.id) }) else { return .ignored }
            preview = first; return .handled
        }
        .onAppear { searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .captureSearchFocus)) { _ in searchFocused = true }
        .sheet(item: $preview) { record in
            CaptureDetail(recordID: record.id, ids: matches.map(\.id)) { preview = nil }
        }
    }
}

extension Notification.Name {
    static let captureSearchFocus = Notification.Name("captureSearchFocus")
}

enum CaptureTags {
    static func merge(_ existing: String, _ added: String) -> String {
        var seen = Set<String>()
        return (existing + "," + added).components(separatedBy: CharacterSet(charactersIn: ",，;；\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.joined(separator: ", ")
    }
}

struct CaptureDetail: View {
    @ObservedObject private var model = WebsiteCapture.shared
    @State var recordID: String
    let ids: [String]
    let close: () -> Void
    @State private var note = ""
    @State private var tags = ""
    @State private var result = ""
    @FocusState private var editing: Bool
    @FocusState private var browsing: Bool
    private var record: CaptureRecord? { model.records.first { $0.id == recordID } }
    private var dirty: Bool { record.map { $0.note != note || $0.tags != tags } ?? false }
    private var locked: Bool { record?.state == "已保存" || record?.state == "正在上传" }
    private var index: Int { ids.firstIndex(of: recordID) ?? 0 }
    private func load() { note = record?.note ?? ""; tags = record?.tags ?? ""; result = "" }
    private func move(_ offset: Int) {
        guard !dirty, ids.indices.contains(index + offset) else { return }
        recordID = ids[index + offset]; load()
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button("上一张") { move(-1) }.disabled(dirty || index == 0)
                Text("\(index + 1) / \(ids.count)")
                Button("下一张") { move(1) }.disabled(dirty || index + 1 >= ids.count)
                Spacer()
                Button("关闭") { close() }.disabled(dirty)
            }
            if let record {
                Text(record.name).lineLimit(1)
                if let image = NSImage(contentsOfFile: record.file) { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: .infinity) }
                HStack(alignment: .top) {
                    VStack(alignment: .leading) {
                        Text("备注")
                        TextEditor(text: $note).focused($editing).frame(height: 72).disabled(locked)
                        TextField("标签，用逗号分隔", text: $tags).focused($editing).disabled(locked)
                        HStack {
                            Button("保存备注与标签") {
                                let savedOK = model.edit(recordID, note: note, tags: CaptureTags.merge("", tags))
                                if let saved = model.records.first(where: { $0.id == recordID }) { tags = saved.tags }
                                result = savedOK ? "已保存到本地" : model.message
                            }.disabled(!dirty || locked)
                            Button("取消修改") { load() }.disabled(!dirty)
                            Text(dirty ? "请保存或取消后再翻图" : result).font(.caption)
                        }
                    }
                    VStack(alignment: .leading) {
                        Text(model.ocrStatus(record)).font(.caption)
                        ScrollView { Text(record.ocrText ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 120)
                    }.frame(maxWidth: .infinity)
                }
                if locked { Text("此记录已上传或正在上传，暂不支持修改。").font(.caption) }
            }
        }
        .padding(16).frame(minWidth: 660, idealWidth: 900, minHeight: 480, idealHeight: 680)
        .focusable()
        .focused($browsing)
        .onAppear { load(); browsing = true }
        .interactiveDismissDisabled(dirty)
        .onKeyPress(.leftArrow) { guard !editing else { return .ignored }; move(-1); return .handled }
        .onKeyPress(.rightArrow) { guard !editing else { return .ignored }; move(1); return .handled }
        .onKeyPress(.escape) { guard !dirty else { return .handled }; close(); return .handled }
    }
}
