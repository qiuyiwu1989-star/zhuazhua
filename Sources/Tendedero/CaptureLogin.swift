import AppKit
import SwiftUI
import WebKit

/// Login stays in a persistent WebKit session; native controls remain usable
/// even when the remote page stalls or its web-content process terminates.
@MainActor
final class CaptureLoginModel: NSObject, ObservableObject, WKNavigationDelegate, NSWindowDelegate {
    let web = WKWebView(frame: .zero)
    @Published var loading = false
    @Published var message = "在下方网站页面登录；爪爪不会保存密码。"
    private var deadline: Task<Void, Never>?
    private static let loginURL = URL(string: "https://qiuyiwu.com/admin/login.html?next=/api/inside/whoami")!

    override init() {
        super.init()
        web.navigationDelegate = self
    }
    func load() {
        stop()
        web.load(URLRequest(url: Self.loginURL, timeoutInterval: 20))
    }
    func stop() {
        deadline?.cancel(); deadline = nil
        loading = false
        web.stopLoading()
    }
    func windowWillClose(_ notification: Notification) { stop() }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        deadline?.cancel()
        loading = true
        message = "正在加载网站…本地设置仍可使用。"
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, self.loading else { return }
            self.stop()
            self.message = "网站加载超时。可重试或在浏览器检查网站；已填写的内容不会主动清空。"
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        deadline?.cancel(); deadline = nil; loading = false
        message = "页面已加载。登录完成后点击“读取工作区”；页面加载成功不代表设备已授权。"
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        deadline?.cancel(); deadline = nil; loading = false
        message = "网站加载失败：\(error.localizedDescription)。可点击重试。"
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        stop(); message = "登录页面已停止响应，请点击重试。"
    }
    func openBrowser() { NSWorkspace.shared.open(Self.loginURL) }
}

private struct LoginWebView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

struct CaptureLoginView: View {
    @ObservedObject var model: CaptureLoginModel
    @ObservedObject private var capture = WebsiteCapture.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if model.loading { ProgressView().controlSize(.small) }
                Text("网站登录").font(.headline)
                Spacer()
                if model.loading { Button("停止加载") { model.stop(); model.message = "已停止加载，可点击重试。" } }
                Button("重新加载") { model.load() }
                Button("浏览器打开") { model.openBrowser() }
            }
            Text(model.message).font(.callout).foregroundStyle(.secondary)
            Text("浏览器与此窗口的登录会话独立；读取工作区需要在此窗口完成登录。").font(.caption).foregroundStyle(.secondary)
            Divider()
            LoginWebView(web: model.web).frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Text(capture.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button(capture.working ? "正在读取…" : "登录完成，读取工作区") {
                    Task { await capture.refreshFolders() }
                }.disabled(capture.working)
            }
        }.padding(14).frame(minWidth: 550, minHeight: 500)
    }
}
