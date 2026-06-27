import SwiftUI
import AppKit
import WebKit

/// 包装 WKWebView，加载会话项目里的自包含看板 HTML（<cwd>/.board/board.html）。
/// 本地文件 + 全内联（无 fetch/外链），用 loadFileURL 即可，无 CORS/服务器需求。
struct BoardWebView: NSViewRepresentable {
    /// 看板 HTML 的绝对路径
    let boardPath: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")  // 透明背景，避免白底闪烁
        webView.navigationDelegate = context.coordinator      // 拦截超链点击 → 外部浏览器
        load(into: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // 路径变化时重新加载（同一窗口切换不同会话的看板）
        if context.coordinator.loadedPath != boardPath {
            load(into: webView, coordinator: context.coordinator)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedPath: String?

        /// 看板里的超链:用户点击 http/https/mailto → 用系统默认浏览器打开,不在看板窗口内导航。
        /// 初始 HTML 加载、页内锚点(#)等其余导航照常放行。
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               ["http", "https", "mailto"].contains(scheme) {
                decisionHandler(.cancel)
                NSWorkspace.shared.open(url)
                return
            }
            decisionHandler(.allow)
        }
    }

    private func load(into webView: WKWebView, coordinator: Coordinator) {
        coordinator.loadedPath = boardPath
        let fileURL = URL(fileURLWithPath: boardPath)
        let baseURL = fileURL.deletingLastPathComponent()
        // 看板 HTML 由 /update-board 生成，往往没有 <meta charset>，loadFileURL 不会
        // 按 UTF-8 解析 → 中文乱码。改为按 UTF-8 读成字符串再 loadHTMLString，编码确定。
        // 读失败（极少）才退回 loadFileURL。
        if let html = try? String(contentsOf: fileURL, encoding: .utf8) {
            webView.loadHTMLString(html, baseURL: baseURL)
        } else {
            webView.loadFileURL(fileURL, allowingReadAccessTo: baseURL)
        }
    }
}

/// 看板窗口控制器：菜单栏应用按需创建一个窗口，重复打开复用同一窗口并切换内容。
@MainActor
final class BoardWindowController {
    static let shared = BoardWindowController()
    private var window: NSWindow?
    private var hosting: NSHostingView<BoardWebView>?

    /// 打开（或聚焦）某会话的看板。每次打开都重新 load，确保拿到 /update-board 的最新内容。
    func show(session: AgentSession) {
        guard let boardPath = session.boardPath else { return }
        NSApp.activate(ignoringOtherApps: true)

        let title = session.title.map { "\(session.projectName) · \($0) — 看板" }
            ?? "\(session.projectName) — 看板"

        let rootView = BoardWebView(boardPath: boardPath)
        if let window, let hosting {
            hosting.rootView = rootView   // 复用窗口：切换到新会话的看板
            window.title = title
            window.makeKeyAndOrderFront(nil)
            return
        }

        let host = NSHostingView(rootView: rootView)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.center()
        window = w
        hosting = host
        w.makeKeyAndOrderFront(nil)
    }
}
