import AppKit
import Carbon
import Combine

enum CaptureAction: String, CaseIterable, Identifiable {
    case region, line, collection, settings, note
    var id: String { rawValue }
    var title: String {
        switch self {
        case .region: return "区域截图"
        case .line: return "显示 / 隐藏收纳栏"
        case .collection: return "打开爪爪搜索"
        case .settings: return "打开设置"
        case .note: return "新建图文笔记"
        }
    }
    var standard: Shortcut? {
        switch self {
        case .line: return .standard
        case .region: return Shortcut(keyCode: kVK_ANSI_S, modifiers: [.control, .option], key: "s")
        case .collection: return Shortcut(keyCode: kVK_ANSI_C, modifiers: [.control, .option], key: "c")
        case .settings, .note: return nil
        }
    }
    var storageKey: String { self == .line ? "shortcut" : "captureShortcut." + rawValue }
    func shortcut(in defaults: UserDefaults = .standard) -> Shortcut? {
        guard let saved = defaults.dictionary(forKey: storageKey) else { return standard }
        guard let code = saved["keyCode"] as? Int,
              let modifiers = saved["modifiers"] as? UInt, let key = saved["key"] as? String else { return nil }
        return Shortcut(keyCode: code, modifiers: NSEvent.ModifierFlags(rawValue: modifiers), key: key)
    }
    func save(_ value: Shortcut?, in defaults: UserDefaults = .standard) {
        defaults.set(value.map { ["keyCode": $0.keyCode, "modifiers": $0.modifiers.rawValue, "key": $0.key] as [String: Any] } ?? [:], forKey: storageKey)
    }
}

@MainActor
final class CaptureShortcuts: ObservableObject {
    static let shared = CaptureShortcuts()
    @Published var revision = 0
    @Published var message = "点击修改，然后按下组合键；Escape 取消，Delete 清除。"
    @Published var recording = false
    private var keys: [CaptureAction: HotKey] = [:]
    private var callbacks: [CaptureAction: () -> Void] = [:]
    private var failures = Set<CaptureAction>()
    private var localMonitor: Any?
    private var capture: Process?
    var prepareCapture: (() -> Void)?

    func configure(line: @escaping () -> Void) {
        callbacks = [.line: line,
                     .region: { [weak self] in self?.takeScreenshot() },
                     .collection: { CaptureDrawer.shared.show() },
                     .settings: { CaptureSettings.shared.show() },
                     .note: { Notes.shared.create() }]
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, !self.recording else { return false }
                    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
                    for action in CaptureAction.allCases {
                        guard self.keys[action] != nil, let shortcut = action.shortcut(),
                              shortcut.keyCode == Int(event.keyCode), shortcut.modifiers == modifiers else { continue }
                        if !event.isARepeat { self.callbacks[action]?() }
                        return true
                    }
                    return false
                }
                return handled ? nil : event
            }
        }
        register()
    }
    func register() {
        keys.removeAll(); failures.removeAll()
        for action in CaptureAction.allCases {
            guard let value = action.shortcut(), let callback = callbacks[action] else { continue }
            if let key = HotKey(value, action: callback) { keys[action] = key }
            else { failures.insert(action) }
        }
        if !failures.isEmpty { message = "快捷键被占用：" + failures.map(\.title).sorted().joined(separator: "、") + "。请修改组合键。" }
        revision += 1
    }
    func label(_ action: CaptureAction) -> String {
        _ = revision
        return (action.shortcut()?.display ?? "未设置") + (failures.contains(action) ? " · 冲突" : "")
    }
    static func conflict(_ value: Shortcut, excluding action: CaptureAction,
                         defaults: UserDefaults = .standard) -> CaptureAction? {
        CaptureAction.allCases.first { candidate in
            guard candidate != action, let other = candidate.shortcut(in: defaults) else { return false }
            return value.keyCode == other.keyCode && value.carbonModifiers == other.carbonModifiers
        }
    }
    func change(_ action: CaptureAction) {
        guard !recording else { return }
        recording = true
        // Temporarily release all our bindings so recording cannot trigger another action.
        keys.removeAll()
        ShortcutRecorder.shared.record(title: action.title) { [weak self] result in
            guard let self else { return }
            self.recording = false
            if let chosen = result { self.apply(chosen, to: action) }
            else { self.register() }
        }
    }
    static func isSystemScreenshot(_ value: Shortcut) -> Bool {
        value.modifiers == [.command, .shift] && [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5].contains(value.keyCode)
    }
    func apply(_ value: Shortcut?, to action: CaptureAction) {
        if let value, Self.isSystemScreenshot(value) {
            message = "这是 macOS 的系统截图快捷键，请选择其他组合；原设置保留。"
            register(); return
        }
        if let value, let duplicate = Self.conflict(value, excluding: action) {
            message = "这个组合键已用于“\(duplicate.title)”，保留原设置。"
            register(); return
        }
        let previous = action.shortcut()
        keys[action] = nil
        if let value, let callback = callbacks[action] {
            guard let key = HotKey(value, action: callback) else {
                message = "无法注册这个组合键，可能被系统或其他应用占用；保留原设置。"
                action.save(previous); register(); return
            }
            keys[action] = key
        }
        action.save(value)
        message = "\(action.title)：\(value?.display ?? "已清除")，立即生效"
        register()
    }
    func reset(_ action: CaptureAction) { apply(action.standard, to: action) }
    func takeScreenshot() {
        guard capture == nil else { message = "截图选区已打开，Escape 可取消"; return }
        // Use the system's capture UI; don't change macOS's own shortcut settings.
        let directory = Inbox.folder
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { message = "无法创建截图目录：\(error.localizedDescription)"; return }
        prepareCapture?()
        let url = directory.appendingPathComponent("Capture-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self else { return }
                self.capture = nil
                if FileManager.default.fileExists(atPath: url.path) {
                    NotificationCenter.default.post(name: .captureShortcutCompleted, object: url)
                    self.message = "截图已加入爪爪"
                } else {
                    self.message = process.terminationStatus == 0 ? "已取消截图" : "截图未完成；若系统提示屏幕录制权限，请在系统设置中允许爪爪后重试。"
                }
            }
        }
        do {
            try process.run(); capture = process
            message = "拖动选择截图区域，Escape 取消"
        } catch { message = "无法启动截图：\(error.localizedDescription)" }
    }
}
extension Notification.Name {
    static let captureShortcutCompleted = Notification.Name("QiuyiwuCapture.shortcutCompleted")
}
