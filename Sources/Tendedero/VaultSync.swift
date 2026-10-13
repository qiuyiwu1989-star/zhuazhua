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
    private var pending = Set<String>()
    private let redirects = CaptureRedirects()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 240
        return URLSession(configuration: config, delegate: redirects, delegateQueue: nil)
    }()
    func openInbox() { NSWorkspace.shared.open(URL(string: "https://qiuyiwu.com/vault/inbox/")!) }
    func enqueue(_ ids: [String], model: WebsiteCapture) {
        guard !ids.isEmpty else { return }
        pending.formUnion(ids)
        guard !busy else { return }
        busy = true
        Task {
            var failures = 0; var successes = 0
            while let id = pending.first {
                pending.remove(id)
                if await sync(id, model: model) { successes += 1 } else { failures += 1 }
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
