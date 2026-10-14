import AppKit
import CryptoKit
import SwiftUI

/// Device credential is local-only; cloud credentials never enter the app.
@MainActor
final class VaultSync: ObservableObject {
    static let shared = VaultSync()
    static let tokenURL = WebsiteCapture.directory.appendingPathComponent(".vault-device-token")
    @Published var message = "原图保留在本地，同步后可在知行档案查看"
    @Published var busy = false
    @Published var automatic = UserDefaults.standard.bool(forKey: "vaultAutomatic") {
        didSet { UserDefaults.standard.set(automatic, forKey: "vaultAutomatic") }
    }
    var connected: Bool { FileManager.default.fileExists(atPath: Self.tokenURL.path) }
    @Published var connecting = false
    @Published var connectionMessage = ""

    /// Explicit file transfer for the current server's shared capture credential.
    /// Never bundle the credential with the public application.
    func importConnection() {
        let panel = NSOpenPanel()
        panel.title = "选择爪爪连接文件"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            connecting = true
            defer { connecting = false }
            do {
                let info = try url.resourceValues(forKeys: [.fileSizeKey])
                guard (info.fileSize ?? 0) <= 4096 else { throw CaptureFailure(message: "连接文件格式不正确") }
                let token = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                try await verify(token)
                try FileManager.default.createDirectory(at: Self.tokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(token.utf8).write(to: Self.tokenURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.tokenURL.path)
                connectionMessage = "连接验证成功。现在可开启自动同步，或手动同步待同步图片。"
            } catch { connectionMessage = "连接未完成：" + error.localizedDescription }
        }
    }
    func checkConnection() {
        Task {
            connecting = true
            defer { connecting = false }
            do {
                try await verify(String(contentsOf: Self.tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
                connectionMessage = "连接验证成功"
            } catch { connectionMessage = "连接验证失败：" + error.localizedDescription }
        }
    }
    private func verify(_ token: String) async throws {
        guard !token.isEmpty, token.count <= 4096,
              !token.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw CaptureFailure(message: "连接文件为空或格式不正确")
        }
        var request = URLRequest(url: URL(string: "https://qiuyiwu.com/api/zhuazhua/captures?limit=1")!, timeoutInterval: 15)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw CaptureFailure(message: "连接凭据无效或已失效，请从已连接电脑重新导出") }
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["items"] is [[String: Any]] else {
            throw CaptureFailure(message: "同步服务暂不可用（HTTP \(status)），请稍后重试")
        }
    }
    func exportConnection() {
        let panel = NSSavePanel()
        panel.title = "导出爪爪连接文件"
        panel.message = "连接文件允许访问你的采集库。仅通过私密方式传给自己的电脑，不要上传到公开位置。"
        panel.nameFieldStringValue = "爪爪连接.zhuazhua-connection"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: Self.tokenURL)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            connectionMessage = "已导出连接文件。在另一台电脑的“同步与存储”中导入即可；两台电脑共用此凭据。"
        } catch { connectionMessage = "导出失败：" + error.localizedDescription }
    }
    private var pending = Set<String>()
    private var completions: [String: (Bool) -> Void] = [:]
    private let redirects = CaptureRedirects()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 240
        return URLSession(configuration: config, delegate: redirects, delegateQueue: nil)
    }()
    func openInbox() { NSWorkspace.shared.open(URL(string: "https://qiuyiwu.com/vault/inbox/")!) }
    func enqueue(_ ids: [String], model: WebsiteCapture, completion: ((Bool) -> Void)? = nil) {
        guard !ids.isEmpty else { return }
        if let completion { for id in ids { completions[id] = completion } }
        pending.formUnion(ids)
        guard !busy else { return }
        busy = true
        Task {
            var failures = 0; var successes = 0
            while let id = pending.first {
                pending.remove(id)
                let success = await sync(id, model: model)
                if success { successes += 1 } else { failures += 1 }
                completions.removeValue(forKey: id)?(success)
            }
            busy = false
            message = failures == 0 ? "已同步 \(successes) 张到知行档案收件箱" : "已同步 \(successes) 张，\(failures) 张待重试；本地原图保留"
        }
    }
    /// Notes keep attachments outside the screenshot ledger until explicitly submitted.
    /// The server preserves any existing image metadata for this idempotent upload.
    func syncAttachment(_ digest: String, file: URL) async throws {
        let bytes = try Data(contentsOf: file)
        guard bytes.count <= 64 * 1024 * 1024,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == digest else {
            throw CaptureFailure(message: "附件校验失败或超过 64 MB，已停止上传")
        }
        let token = try String(contentsOf: Self.tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw CaptureFailure(message: "尚未连接知行档案设备") }
        let now = ISO8601DateFormatter().string(from: Date())
        let payload: [String: Any] = ["digest": digest, "image": bytes.base64EncodedString(), "name": "图片附件.png",
            "note": "", "tags": "", "ocr": "", "collectedAt": now, "modifiedAt": now, "attachmentOnly": true]
        var request = URLRequest(url: URL(string: "https://qiuyiwu.com/api/zhuazhua/captures")!)
        request.httpMethod = "POST"; request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200, json?["ok"] as? Bool == true,
              json?["digest"] as? String == digest, json?["storage"] as? String == "cos" else {
            throw CaptureFailure(message: "图片附件同步失败；本地原件保留，请重试")
        }
    }
    func sync(_ id: String, model: WebsiteCapture) async -> Bool {
        guard let record = model.records.first(where: { $0.id == id }) else { return false }
        do {
            let token = try String(contentsOf: Self.tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw CaptureFailure(message: "尚未连接知行档案设备") }
            let bytes = try Data(contentsOf: URL(fileURLWithPath: record.file))
            guard bytes.count <= 64 * 1024 * 1024 else { throw CaptureFailure(message: "图片超过 64 MB") }
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard digest == record.id else { throw CaptureFailure(message: "本地原图校验失败，已停止上传") }
            let formatter = ISO8601DateFormatter()
            let payload: [String: Any] = ["digest": digest, "image": bytes.base64EncodedString(),
                "name": record.name, "note": record.note, "tags": record.tags, "ocr": record.ocrText ?? "",
                "collectedAt": formatter.string(from: record.created), "modifiedAt": formatter.string(from: Date())]
            var request = URLRequest(url: URL(string: "https://qiuyiwu.com/api/zhuazhua/captures")!)
            request.httpMethod = "POST"
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            message = "正在同步：" + record.name
            let (data, response) = try await session.data(for: request)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  json?["ok"] as? Bool == true, json?["digest"] as? String == digest,
                  json?["storage"] as? String == "cos" else {
                throw CaptureFailure(message: json?["error"] as? String ?? "同步未完成，请检查连接后重试")
            }
            if let i = model.records.firstIndex(where: { $0.id == id }) {
                let unchanged = model.records[i].note == record.note && model.records[i].tags == record.tags && model.records[i].ocrText == record.ocrText
                model.records[i].vaultSyncedAt = unchanged ? Date() : nil
                model.records[i].vaultError = nil
                try model.persist()
                if !unchanged && automatic { pending.insert(id) }
            }
            return true
        } catch {
            if let i = model.records.firstIndex(where: { $0.id == id }) {
                model.records[i].vaultError = error is CocoaError && !connected ? "尚未连接知行档案设备" : error.localizedDescription
                try? model.persist()
            }
            return false
        }
    }
}
