import AppKit
import SwiftUI
import WebKit
import ServiceManagement

@MainActor
final class CaptureSettings {
    static let shared = CaptureSettings()
    var onOpen: (() -> Void)?
    var onApply: (() -> Void)?
    var onFolder: (() -> Void)?
    private var window: NSWindow?
    private var loginWindow: NSWindow?
    func show(collection: Bool = false, recordID: String? = nil) {
        onOpen?()
        WebsiteCapture.shared.page = collection ? 0 : 1
        if let recordID { WebsiteCapture.shared.selection = recordID }
        if window == nil {
            let view = CaptureSettingsView(model: .shared, initialCollection: collection)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "爪爪"
            w.contentView = NSHostingView(rootView: view)
            w.minSize = NSSize(width: 720, height: 540)
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
            w.center(); window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func hideForCapture() { window?.orderOut(nil); loginWindow?.orderOut(nil) }
    func login() {
        if loginWindow == nil {
            let web = WKWebView(frame: .zero)
            web.load(URLRequest(url: URL(string: "https://qiuyiwu.com/admin/login.html?next=/api/inside/whoami")!))
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 660),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "登录 qiuyiwu.com · 完成后关闭此窗口并读取工作区"
            w.contentView = web; w.isReleasedWhenClosed = false
            w.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
            w.center(); loginWindow = w
        } else if let web = loginWindow?.contentView as? WKWebView {
            web.load(URLRequest(url: URL(string: "https://qiuyiwu.com/admin/login.html?next=/api/inside/whoami")!))
        }
        NSApp.activate(ignoringOtherApps: true); loginWindow?.makeKeyAndOrderFront(nil)
    }
}

struct CaptureSettingsView: View {
    @ObservedObject var model: WebsiteCapture
    @ObservedObject private var vault = VaultSync.shared
    @ObservedObject private var events = NoteEvents.shared
    @ObservedObject private var shortcuts = CaptureShortcuts.shared
    let initialCollection: Bool
    @State private var note = ""
    @State private var tags = ""
    @State private var inbox = Inbox.isEnabled
    @State private var clipboard = ClipboardWatcher.isEnabled
    @State private var hover = AppDelegate.opensFromMenuBar
    @State private var peek = AppDelegate.peeksAtNew
    @State private var fullscreen = FullScreen.showLineOver
    @State private var sound = !UserDefaults.standard.bool(forKey: "soundOff")
    @State private var size = Layout.size.rawValue
    @State private var keep = Line.keepOnLine ?? 0
    @State private var startup = SMAppService.mainApp.status == .enabled
    @State private var settingsMessage = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "tray.and.arrow.down.fill").font(.title).foregroundStyle(.teal)
                VStack(alignment: .leading) {
                    Text("爪爪").font(.title2.bold())

                    Text("桌面暂存，保存到你的 qiuyiwu.com 工作区").foregroundStyle(.secondary)
                }
                Spacer()
                Button("打开本地原件") { NSWorkspace.shared.open(WebsiteCapture.directory) }
            }
            Picker("页面", selection: $model.page) {
                Text("采集记录").tag(0); Text("网站与工作区").tag(1); Text("常规设置").tag(2); Text("快捷键").tag(3)
            }.pickerStyle(.segmented)
            if model.page == 0 { collection }
            else if model.page == 1 { website }
            else if model.page == 2 { preferences }
            else { shortcutSettings }
            Divider()
            Text(model.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .padding(22)
        .onAppear {
            let r = model.records.first { $0.id == model.selection }
            note = r?.note ?? ""; tags = r?.tags ?? ""
        }
        .onChange(of: model.selection) { _, id in
            let r = model.records.first { $0.id == id }
            note = r?.note ?? ""; tags = r?.tags ?? ""
        }
    }
    private var collection: some View {
        HStack(alignment: .top, spacing: 18) {
            List(selection: $model.selection) {
                ForEach(model.records) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.name).lineLimit(1)
                        Text(r.state + (r.folderName.isEmpty ? "" : " · " + r.folderName))
                            .font(.caption).foregroundStyle(r.state == "已保存" ? .green : .secondary)
                    }.padding(.vertical, 4).tag(r.id)
                }
            }.frame(minWidth: 250, maxWidth: 310)
            if let id = model.selection, let r = model.records.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 10) {
                    if let img = NSImage(contentsOfFile: r.file) {
                        Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 175)
                    }
                    Text(r.state).font(.headline)
                    if let error = r.error { Text(error).foregroundStyle(.red).font(.caption) }
                    TextField("标签，用逗号分隔", text: $tags)
                    TextEditor(text: $note).frame(minHeight: 70).border(.quaternary)
                    Text("备注和标签会作为同工作区内的 Markdown 附件保存。").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("保存备注") { model.edit(id, note: note, tags: tags) }
                        Spacer()
                        Button(r.state == "待重试" ? "重试保存" : "保存到工作区") {
                            model.edit(id, note: note, tags: tags)
                            Task { await model.save(id) }
                        }.buttonStyle(.borderedProminent)
                    }.disabled(r.state == "正在上传" || r.state == "已保存")
                    HStack {
                        Button("查看本地原件") { NSWorkspace.shared.open(URL(fileURLWithPath: r.file)) }
                        if r.state == "已保存" { Button("打开网站原件") { model.openRemote(r) } }
                    }
                }.frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled").font(.largeTitle)
                    Text(model.records.isEmpty ? "截个图，资料会出现在这里" : "选择一张图片，添加备注并保存")
                    Text("原件留在本地，收纳栏满了也不会删除。").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxHeight: .infinity)
    }
    private var website: some View {
        Form {
            Section("知行档案 · 爪爪收件箱") {
                Text(vault.connected ? "设备已连接 · 原图保存到 COS" : "设备尚未连接")
                Toggle("自动同步新采集和后续整理到知行档案", isOn: $vault.automatic).disabled(!vault.connected)
                HStack {
                    Button("同步所有待同步图片") {
                        vault.enqueue(model.records.filter { $0.vaultSyncedAt == nil || $0.vaultError != nil }.map(\.id), model: model)
                    }.disabled(vault.busy || !vault.connected)
                    Button("打开知行档案收件箱") { vault.openInbox() }
                }
                Text(vault.message).font(.caption).textSelection(.enabled)
                Text("原图、OCR、备注、标签和采集时间一起同步；同一原图重复提交不会新增记录。网站需登录查看。").font(.caption).foregroundStyle(.secondary)
            }
            Section("原有网站工作区（兼容）") {
                Text("https://qiuyiwu.com").textSelection(.enabled)
                HStack {
                    Button("登录网站") { CaptureSettings.shared.login() }
                    Button("读取工作区") { Task { await model.refreshFolders() } }.disabled(model.working)
                    if model.working { ProgressView().controlSize(.small) }
                }
                Text("在网站原有页面登录；登录会话由 macOS WebKit 管理，不保存密码。").font(.caption).foregroundStyle(.secondary)
            }
            Section("默认保存位置") {
                Picker("工作区文件夹", selection: $model.selectedFolder) {
                    Text("请选择工作区").tag("")
                    if !model.selectedFolder.isEmpty && !model.folders.contains(where: { $0.id == model.selectedFolder }) {
                        Text("已选工作区（读取列表以验证）").tag(model.selectedFolder)
                    }
                    ForEach(model.folders) { f in Text(String(repeating: "　", count: min(f.depth ?? 0, 8)) + f.name).tag(f.id) }
                }
                Button("创建 / 使用「桌面采集」工作区") { Task { await model.createFolder() } }.disabled(model.working)
                Text("使用网站现有资料库文件夹，不会公开发布图片。").font(.caption).foregroundStyle(.secondary)
            }
            Section("保存方式") {
                Toggle("自动保存之后的新截图到选定工作区", isOn: $model.automatic)
                    .disabled(model.selectedFolder.isEmpty)
                Text("默认手动保存。自动保存只作用于开启后的新条目；失败保留本地副本，可在采集记录中重试。").font(.caption).foregroundStyle(.secondary)
                Text("上传成功后仍保留本地原件。").font(.caption)
            }
        }.formStyle(.grouped).frame(maxHeight: .infinity)
    }
    private var shortcutSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("全局快捷键").font(.headline)
            Text("爪爪运行时，在其他应用及全屏中也可使用。修改后立即生效。").foregroundStyle(.secondary)
            ForEach(CaptureAction.allCases) { action in
                HStack {
                    Text(action.title).frame(width: 160, alignment: .leading)
                    Text(shortcuts.label(action)).font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("修改…") { shortcuts.change(action) }.help("修改" + action.title + "快捷键")
                    Button("清除") { shortcuts.apply(nil, to: action) }.help("清除" + action.title + "快捷键")
                    Button("恢复默认") { shortcuts.reset(action) }
                }
                Divider()
            }
            Text(shortcuts.message).foregroundStyle(.secondary).textSelection(.enabled)
            Text("区域截图调用 macOS 选区工具，Escape 取消。系统原有的 ⌘⇧3 / ⌘⇧4 / ⌘⇧5 不会被改动；尽量避免使用这些已被系统占用的组合键。")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }.padding(.top, 12).disabled(shortcuts.recording)
    }

    private var preferences: some View {
        Form {
            Section("体验改进") {
                Toggle("发送匿名使用计数", isOn: $events.enabled)
                Text("默认关闭。仅统计笔记打开、导入和同步结果，不发送正文、图片、路径、来源或搜索词。").font(.caption).foregroundStyle(.secondary)
            }
            Section("采集") {
                Toggle("接管系统截图保存位置", isOn: $inbox)
                Toggle("收集剪贴板中的图片", isOn: $clipboard)
                Button("添加监听文件夹…") { CaptureSettings.shared.onFolder?() }
                ForEach(AppDelegate.extraFolders, id: \.path) { url in
                    HStack {
                        Text(url.lastPathComponent)
                        Button("停止监听") {
                            AppDelegate.extraFolders.removeAll { $0 == url }; CaptureSettings.shared.onApply?()
                            settingsMessage = "已停止监听 \(url.lastPathComponent)"
                        }
                    }
                }
            }
            Section("显示与操作") {
                Toggle("鼠标移到顶部时展开", isOn: $hover)
                Toggle("新截图出现时短暂展开", isOn: $peek)
                Toggle("在全屏应用上显示", isOn: $fullscreen)
                Toggle("交互提示音", isOn: $sound)
                Picker("卡片大小", selection: $size) {
                    Text("小").tag("small"); Text("中").tag("medium"); Text("大").tag("large")
                }
                Picker("栏内保留数量", selection: $keep) {
                    Text("适应屏幕").tag(0)
                    ForEach(Line.keepChoices, id: \.self) { Text("\($0) 张").tag($0) }
                }
                Toggle("开机启动", isOn: $startup)
            }
            Button("应用设置") {
                Inbox.isEnabled = inbox; ClipboardWatcher.isEnabled = clipboard
                AppDelegate.opensFromMenuBar = hover; AppDelegate.peeksAtNew = peek
                FullScreen.showLineOver = fullscreen
                UserDefaults.standard.set(!sound, forKey: "soundOff")
                Layout.size = Layout.Size(rawValue: size) ?? .medium
                Line.keepOnLine = keep == 0 ? nil : keep
                CaptureSettings.shared.onApply?()
                do {
                    if startup && SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
                    if !startup && SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                    settingsMessage = "设置已应用"
                } catch { settingsMessage = "其他设置已应用，开机启动失败：\(error.localizedDescription)" }
            }.buttonStyle(.borderedProminent)
            Text(settingsMessage).font(.caption)
        }.formStyle(.grouped).frame(maxHeight: .infinity)
    }
}
