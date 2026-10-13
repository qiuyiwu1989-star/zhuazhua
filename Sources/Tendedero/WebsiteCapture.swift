import AppKit
import SwiftUI
import WebKit
import CryptoKit

struct CaptureFolder: Codable, Identifiable {
    let id: String
    let name: String
    var depth: Int?
}
struct CaptureRecord: Codable, Identifiable {
    var id: String
    var source: String
    var file: String
    var name: String
    var created: Date
    var note = ""
    var tags = ""
    var folder = ""
    var folderName = ""
    var state = "已收集"
    var digest: String?
    var noteDigest: String?
    var error: String?
    var organizedAt: [Date]?
    var ocrText: String?
    var ocrError: String?
}
struct CaptureFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Requests use only cookies belonging to the fixed first-party HTTPS origin.
// A login redirect is an error, never an upload success or a credential handoff.
final class CaptureRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class WebsiteCapture: ObservableObject {
    static let shared = WebsiteCapture()
    static let base = URL(string: "https://qiuyiwu.com")!
    nonisolated static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("QiuyiwuCapture", isDirectory: true)
    @Published var recognizing = Set<String>()
    private var ocrEnabled = false
    @Published var records: [CaptureRecord] = []
    @Published var folders: [CaptureFolder] = []
    @Published var message = "请登录 qiuyiwu.com，然后读取工作区"
    @Published var working = false
    @Published var page = 1
    @Published var selection: String?
    @Published var selectedFolder: String {
        didSet { preferences.set(selectedFolder, forKey: "captureFolder") }
    }
    @Published var automatic: Bool {
        didSet { preferences.set(automatic, forKey: "captureAutomatic") }
    }
    var onSettings: (() -> Void)?
    private var active = Set<String>()
    private let storage: URL
    private let preferences: UserDefaults
    private let suppliedSession: URLSession?
    private let cookiesProvider: () async -> [HTTPCookie]
    private var ledgerReadable = true
    private let redirects = CaptureRedirects()
    private lazy var session: URLSession = {
        if let suppliedSession { return suppliedSession }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: redirects, delegateQueue: nil)
    }()
    private var ledger: URL { storage.appendingPathComponent("captures.json") }
    init(storage: URL = WebsiteCapture.directory, preferences: UserDefaults = .standard,
         session: URLSession? = nil,
         cookies: @escaping () async -> [HTTPCookie] = { await WKWebsiteDataStore.default().httpCookieStore.allCookies() }) {
        self.storage = storage; self.preferences = preferences; self.suppliedSession = session; self.cookiesProvider = cookies
        selectedFolder = preferences.string(forKey: "captureFolder") ?? ""
        automatic = preferences.bool(forKey: "captureAutomatic")
        do {
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: ledger.path) {
                records = try JSONDecoder().decode([CaptureRecord].self, from: Data(contentsOf: ledger))
                for i in records.indices where records[i].state == "待保存" { records[i].state = "已收集" }
                for i in records.indices where records[i].state == "正在上传" {
                    records[i].state = "待重试"
                    records[i].error = "上次上传中断，原件已保留"
                }
            }
        } catch { ledgerReadable = false; message = "读取本地采集记录失败：\(error.localizedDescription)" }
    }
    func startOCR() {
        ocrEnabled = true
        for record in records where record.ocrText == nil { recognize(record.id) }
    }
    func recognize(_ id: String) {
        guard ledgerReadable, !recognizing.contains(id), let record = records.first(where: { $0.id == id }) else { return }
        recognizing.insert(id)
        Task {
            defer { recognizing.remove(id) }
            do {
                let text = try await CaptureOCR.shared.recognize(file: record.file)
                guard let i = records.firstIndex(where: { $0.id == id }) else { return }
                records[i].ocrText = text
                records[i].ocrError = nil
                try persist()
            } catch {
                if let i = records.firstIndex(where: { $0.id == id }) { records[i].ocrError = error.localizedDescription }
                message = "文字识别失败，可右键图片重试：\(error.localizedDescription)"
            }
        }
    }
    func ocrStatus(_ record: CaptureRecord) -> String {
        if recognizing.contains(record.id) { return "正在识别文字…" }
        if record.ocrError != nil { return "识别失败 · 右键重试" }
        guard let text = record.ocrText else { return "等待识别" }
        return text.isEmpty ? "未识别到文字" : "文字可搜索"
    }
    func persist() throws {
        guard ledgerReadable else { throw CaptureFailure(message: "本地记录无法读取，已停止写入以保护原记录") }
        try JSONEncoder().encode(records).write(to: ledger, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledger.path)
    }
    @discardableResult
    func stage(_ url: URL, allowAutomatic: Bool = true) -> String? {
        do {
            guard ledgerReadable else { throw CaptureFailure(message: "本地记录无法读取，请先恢复记录文件") }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 64 * 1024 * 1024, !isRecording(url) else {
                throw CaptureFailure(message: "目前网站采集支持 64 MB 以内图片；视频原件保留在截图目录")
            }
            let bytes = try Data(contentsOf: url)
            let id = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            if records.contains(where: { $0.id == id }) { return id }
            let ext = url.pathExtension.lowercased()
            let local = storage.appendingPathComponent(id).appendingPathExtension(ext)
            try bytes.write(to: local, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: local.path)
            records.insert(CaptureRecord(id: id, source: url.path, file: local.path,
                                         name: url.lastPathComponent, created: Date()), at: 0)
            try persist()
            if ocrEnabled { recognize(id) }
            if allowAutomatic && automatic && !selectedFolder.isEmpty { Task { await save(id) } }
            return id
        } catch { message = "本地暂存失败：\(error.localizedDescription)"; return nil }
    }
    @discardableResult
    func edit(_ id: String, note: String, tags: String) -> Bool {
        guard let i = records.firstIndex(where: { $0.id == id }), !active.contains(id), records[i].state != "已保存" else { return false }
        guard records[i].note != note || records[i].tags != tags else { return true }
        let previous = records[i]
        if records[i].note != note || records[i].tags != tags { records[i].noteDigest = nil }
        records[i].note = note; records[i].tags = tags
        records[i].organizedAt = (records[i].organizedAt ?? []) + [Date()]
        do { try persist(); return true } catch { records[i] = previous; message = "保存备注失败：\(error.localizedDescription)"; return false }
    }
    func status(_ url: URL) -> String? { records.first(where: { $0.source == url.path || $0.file == url.path })?.state }
    func request(_ path: String, method: String = "GET", body: Data? = nil,
                 contentType: String = "application/json") async throws -> [String: Any] {
        let url = Self.base.appendingPathComponent(path)
        let cookies = await cookiesProvider()
        let firstParty = cookies.filter {
            ($0.domain == "qiuyiwu.com" || $0.domain == ".qiuyiwu.com") &&
            ($0.expiresDate == nil || $0.expiresDate! > Date()) && url.path.hasPrefix($0.path)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method; req.httpBody = body
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in HTTPCookie.requestHeaderFields(with: firstParty) { req.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw CaptureFailure(message: "网站响应无效") }
        if [301,302,303,307,308,401,403].contains(http.statusCode) {
            throw CaptureFailure(message: "请先登录网站，或重新登录后重试")
        }
        guard (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CaptureFailure(message: "网站请求失败（HTTP \(http.statusCode)），本地原件已保留")
        }
        if json["ok"] as? Bool == false { throw CaptureFailure(message: json["error"] as? String ?? "网站未接受请求") }
        return json
    }
    func jsonRequest(_ path: String, _ value: [String: Any]) async throws -> [String: Any] {
        try await request(path, method: "POST", body: JSONSerialization.data(withJSONObject: value))
    }
    func refreshFolders() async {
        working = true; defer { working = false }
        do {
            let result = try await request("api/inside/mine/folders")
            guard let rows = result["items"] as? [[String: Any]] else { throw CaptureFailure(message: "工作区列表格式不匹配") }
            folders = try JSONDecoder().decode([CaptureFolder].self, from: JSONSerialization.data(withJSONObject: rows))
            message = "已连接 · \(folders.count) 个工作区文件夹"
        } catch { message = error.localizedDescription }
    }
    func createFolder() async {
        working = true
        do {
            let result = try await jsonRequest("api/inside/mine/folders", ["name": "桌面采集", "parent": "root"])
            guard let folder = result["folder"] as? [String: Any], let id = folder["id"] as? String else {
                throw CaptureFailure(message: "创建工作区失败")
            }
            await refreshFolders(); selectedFolder = id
        } catch { message = error.localizedDescription }
        working = false
    }
    static func multipart(_ bytes: Data, filename: String, mime: String, boundary: String) -> Data {
        // ASCII filename avoids header injection; original names are kept locally.
        var data = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"owner\"\r\n\r\nunknown\r\n".utf8)
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        data.append(bytes); data.append(Data("\r\n--\(boundary)--\r\n".utf8)); return data
    }
    private func upload(_ bytes: Data, filename: String, mime: String) async throws -> String {
        let boundary = "Capture-" + UUID().uuidString
        let result = try await request("api/inside/mine/upload", method: "POST",
            body: Self.multipart(bytes, filename: filename, mime: mime, boundary: boundary),
            contentType: "multipart/form-data; boundary=\(boundary)")
        guard let files = result["files"] as? [[String: Any]], let first = files.first,
              first["ok"] as? Bool == true, let digest = first["digest"] as? String,
              digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else {
            throw CaptureFailure(message: "文件未保存到网站，请重试")
        }
        return digest
    }
    func save(_ id: String) async {
        guard !active.contains(id), let start = records.first(where: { $0.id == id }), start.state != "已保存" else { return }
        let folderID = start.folder.isEmpty ? selectedFolder : start.folder
        guard !folderID.isEmpty else { message = "先在设置中选择保存工作区"; onSettings?(); return }
        active.insert(id); defer { active.remove(id) }
        func update(_ change: (inout CaptureRecord) -> Void) throws {
            guard let i = records.firstIndex(where: { $0.id == id }) else { return }
            change(&records[i]); try persist()
        }
        do {
            try update { r in
                r.folder = folderID
                if r.folderName.isEmpty { r.folderName = folders.first(where: { $0.id == folderID })?.name ?? folderID }
                r.state = "正在上传"; r.error = nil
            }
            let bytes = try await Task.detached { try Data(contentsOf: URL(fileURLWithPath: start.file)) }.value
            let ext = URL(fileURLWithPath: start.file).pathExtension
            let digest: String
            if let existing = start.digest { digest = existing }
            else {
                digest = try await upload(bytes, filename: "capture-\(id.prefix(12)).\(ext)", mime: "application/octet-stream")
                try update { $0.digest = digest }
            }
            var digests = [digest]
            // Existing website API has no annotation field: preserve notes as a companion Markdown file.
            if !start.note.isEmpty || !start.tags.isEmpty {
                let noteDigest: String
                if let existing = start.noteDigest { noteDigest = existing }
                else {
                    let md = "# 桌面采集备注\n\n图片标识：\(digest)\n\n采集时间：\(ISO8601DateFormatter().string(from: start.created))\n\n标签：\(start.tags)\n\n\(start.note)\n"
                    noteDigest = try await upload(Data(md.utf8), filename: "capture-\(id.prefix(12))-note.md", mime: "text/markdown")
                    try update { $0.noteDigest = noteDigest }
                }
                digests.append(noteDigest)
            }
            let result = try await jsonRequest("api/inside/mine/place", ["digests": digests, "folder": folderID])
            guard result["ok"] as? Bool == true, (result["moved"] as? Int ?? 0) == digests.count else {
                throw CaptureFailure(message: "文件已上传，但归入工作区未完成，请重试")
            }
            try update { $0.state = "已保存"; $0.error = nil }
            message = "已保存到工作区，本地原件保留"
        } catch {
            try? update { $0.state = "待重试"; $0.error = error.localizedDescription }
            message = error.localizedDescription
        }
    }
    func openRemote(_ record: CaptureRecord) {
        guard let digest = record.digest else { return }
        // Reuses the protected original-file endpoint; no public share link is created.
        NSWorkspace.shared.open(Self.base.appendingPathComponent("api/inside/mine/\(digest)/raw"))
    }
}
