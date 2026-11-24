import SwiftUI
import WebKit
import AVFoundation
import UniformTypeIdentifiers

@main
struct ArcadeApp: App {
    init() {
        // Game sound plays even when the ring switch is on silent, and does not stop the player's own music.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            ArcadeView()
                .ignoresSafeArea()
                .background(Color(red: 10 / 255, green: 8 / 255, blue: 24 / 255))
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
        }
    }
}

/// Serves the bundled web arcade under arcade://app/, so absolute links, ES modules and storage behave as they do on the site.
/// Calls to /api/ are passed on to the live site, which keeps accounts and rooms working when the phone is online.
final class BundleScheme: NSObject, WKURLSchemeHandler {
    static let scheme = "arcade"
    private let root = Bundle.main.url(forResource: "Web", withExtension: nil)
    private let live = URL(string: "https://launch.mountlayer.com")!
    private var stopped = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { task.didFailWithError(URLError(.badURL)); return }
        if url.path.hasPrefix("/api/") { forward(task, url); return }
        guard let root = root else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
        var file = root.appendingPathComponent(url.path)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), isDir.boolValue { file = file.appendingPathComponent("index.html") }
        guard file.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path), let data = try? Data(contentsOf: file) else {
            let r = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
            task.didReceive(r); task.didReceive(Data("not found".utf8)); task.didFinish(); return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let type = mime.hasPrefix("text/") || mime.contains("javascript") || mime.contains("json") ? mime + "; charset=utf-8" : mime
        let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type, "Content-Length": String(data.count), "Cache-Control": "no-cache"])!
        task.didReceive(r); task.didReceive(data); task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { stopped.insert(ObjectIdentifier(task)) }

    private func forward(_ task: WKURLSchemeTask, _ url: URL) {
        var comps = URLComponents(url: live, resolvingAgainstBaseURL: false)!
        comps.path = url.path; comps.query = url.query
        var req = URLRequest(url: comps.url!)
        req.httpMethod = task.request.httpMethod ?? "GET"
        req.httpBody = task.request.httpBody
        for (k, v) in task.request.allHTTPHeaderFields ?? [:] where ["content-type", "authorization", "accept"].contains(k.lowercased()) { req.setValue(v, forHTTPHeaderField: k) }
        let id = ObjectIdentifier(task)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                if self.stopped.remove(id) != nil { return }
                guard let http = resp as? HTTPURLResponse, let data = data else { task.didFailWithError(err ?? URLError(.badServerResponse)); return }
                let r = HTTPURLResponse(url: url, statusCode: http.statusCode, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": http.value(forHTTPHeaderField: "Content-Type") ?? "application/json"])!
                task.didReceive(r); task.didReceive(data); task.didFinish()
            }
        }.resume()
    }
}

struct ArcadeView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.setURLSchemeHandler(BundleScheme(), forURLScheme: BundleScheme.scheme)
        let content = config.userContentController
        content.add(context.coordinator, name: "haptic")
        // navigator.vibrate goes to the Taptic Engine; audio contexts are woken on every touch and kept on the playback route.
        let boot = """
        navigator.vibrate = function (p) { try { webkit.messageHandlers.haptic.postMessage(Array.isArray(p) ? p.reduce(function (a, b) { return a + b; }, 0) : (p || 0)); } catch (e) {} return true; };
        (function () {
          var Base = window.AudioContext || window.webkitAudioContext; if (!Base) return;
          var all = [];
          var Tracked = class extends Base { constructor(o) { super(o); all.push(this); } };
          window.AudioContext = Tracked; if (window.webkitAudioContext) window.webkitAudioContext = Tracked;
          try { if (navigator.audioSession) navigator.audioSession.type = 'playback'; } catch (e) {}
          var wake = function () { all.forEach(function (c) { if (c.state !== 'running') { try { c.resume(); } catch (e) {} } }); };
          ['touchstart', 'touchend', 'pointerup', 'click'].forEach(function (t) { addEventListener(t, wake, true); });
          document.addEventListener('visibilitychange', function () { if (!document.hidden) setTimeout(wake, 150); });
        })();
        document.addEventListener('DOMContentLoaded', function () {
          var s = document.createElement('style'); s.textContent = 'body{-webkit-touch-callout:none}'; document.head.appendChild(s);
        });
        """
        content.addUserScript(WKUserScript(source: boot, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 10 / 255, green: 8 / 255, blue: 24 / 255, alpha: 1)
        web.scrollView.backgroundColor = web.backgroundColor
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.allowsLinkPreview = false
        web.allowsBackForwardNavigationGestures = true
        // "-start /race/" on the command line opens one game directly (used for checks in the simulator).
        let start = UserDefaults.standard.string(forKey: "start") ?? "/games/"
        web.load(URLRequest(url: URL(string: "arcade://app" + start)!))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        private let light = UIImpactFeedbackGenerator(style: .light)
        private let heavy = UIImpactFeedbackGenerator(style: .heavy)

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let ms = (message.body as? NSNumber)?.doubleValue ?? 0
            (ms >= 30 ? heavy : light).impactOccurred()
        }

        // Pages of the bundled arcade stay in the app; anything on the open web (share links, the company site) goes to Safari.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if url.scheme == BundleScheme.scheme || url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" { decisionHandler(.allow); return }
            if url.scheme == "http" || url.scheme == "https" { UIApplication.shared.open(url) }
            decisionHandler(.cancel)
        }

        // window.open: bundled pages open in place, web links in Safari.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url { if url.scheme == BundleScheme.scheme { webView.load(action.request) } else if url.scheme == "http" || url.scheme == "https" { UIApplication.shared.open(url) } }
            return nil
        }
    }
}
