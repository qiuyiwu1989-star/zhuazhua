import AppKit
import SwiftUI

struct AppRelease: Decodable {
    struct Asset: Decodable { let name: String; let browser_download_url: String }
    let tag_name: String
    let html_url: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    var version: String { String(tag_name.drop(while: { $0 == "v" })) }
    static func components(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == 3 && numbers.allSatisfy { $0 >= 0 } ? numbers : nil
    }
    static func newer(_ lhs: String, than rhs: String) -> Bool {
        guard let a = components(lhs), let b = components(rhs) else { return false }
        return b.lexicographicallyPrecedes(a)
    }
    var downloadURL: URL? {
        guard Self.components(version) != nil,
              let asset = assets.first(where: { $0.name == "ZhuaZhua-\(version)-macOS.zip" }),
              let url = URL(string: asset.browser_download_url),
              url.scheme == "https", url.host == "github.com",
              url.path == "/qiuyiwu1989-star/zhuazhua/releases/download/\(tag_name)/\(asset.name)" else { return nil }
        return url
    }
}

@MainActor
final class AppUpdates: ObservableObject {
    static let shared = AppUpdates()
    @Published var automatic: Bool = UserDefaults.standard.object(forKey: "automaticUpdateChecks") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(automatic, forKey: "automaticUpdateChecks")
            if automatic { Task { await check() } }
        }
    }
    @Published var checking = false
    @Published var message = "检查 GitHub 上发布的新版本"
    @Published var available: AppRelease?
    private var timer: Timer?
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    func start() {
        guard timer == nil else { return }
        if automatic { Task { await check() } }
        timer = Timer.scheduledTimer(withTimeInterval: 12 * 60 * 60, repeats: true) { _ in
            Task { @MainActor in if Self.shared.automatic { await Self.shared.check() } }
        }
    }
    func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        message = "正在检查更新…"
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/qiuyiwu1989-star/zhuazhua/releases?per_page=30")!, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("ZhuaZhua-UpdateCheck", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CaptureFailure(message: "更新服务暂不可用，请稍后重试") }
            let releases = try JSONDecoder().decode([AppRelease].self, from: data)
                .filter { !$0.draft && $0.downloadURL != nil }
                .sorted { AppRelease.newer($0.version, than: $1.version) }
            guard let latest = releases.first else { throw CaptureFailure(message: "暂未找到可下载的版本") }
            available = AppRelease.newer(latest.version, than: currentVersion) ? latest : nil
            message = available == nil ? "当前已是最新版本 \(currentVersion)" : "发现 \(latest.version)\(latest.prerelease ? " 预览版" : "")"
        } catch { message = "检查未完成：" + error.localizedDescription }
    }
}

struct AppUpdateSettings: View {
    @ObservedObject private var updates = AppUpdates.shared
    var body: some View {
        Section("软件更新") {
            Toggle("自动检查更新", isOn: $updates.automatic)
            Text("启动时及每 12 小时检查 GitHub 发布，包括预览版。只查询版本，不发送采集内容；不会自动安装或重启。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("立即检查") { Task { await updates.check() } }.disabled(updates.checking)
                if updates.checking { ProgressView().controlSize(.small) }
                Text(updates.message).font(.callout).textSelection(.enabled)
            }
            if let release = updates.available, let url = release.downloadURL {
                Link("下载 \(release.version)", destination: url)
                DisclosureGroup("更新说明") { Text(release.body ?? "请查看 GitHub 版本记录").font(.callout).textSelection(.enabled) }
                Text("下载完成后退出爪爪，用新应用替换旧应用；本地资料与设置保留。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
