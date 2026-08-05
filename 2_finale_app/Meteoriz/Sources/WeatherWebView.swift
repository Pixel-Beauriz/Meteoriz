import SwiftUI
import UIKit
import WebKit

struct WeatherWebView: UIViewRepresentable {
    @ObservedObject var diagnostics: DiagnosticsLog
    @ObservedObject var refreshState: RefreshState

    private static let backgroundColor = UIColor(red: 6/255, green: 8/255, blue: 13/255, alpha: 1)

    func makeCoordinator() -> Coordinator {
        Coordinator(diagnostics: diagnostics, refreshState: refreshState)
    }

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "geoBridge")
        contentController.add(context.coordinator, name: "diagBridge")
        contentController.add(context.coordinator, name: "geocodeBridge")

        for script in ["geo-bridge", "diagnostics-bridge", "native-geocoding-bridge", "layout-fix"] {
            if let url = Bundle.main.url(forResource: script, withExtension: "js", subdirectory: "Web"),
               let source = try? String(contentsOf: url, encoding: .utf8) {
                let userScript = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
                contentController.addUserScript(userScript)
            } else {
                diagnostics.log(.error, source: "Bundle", "Skript \(script).js konnte nicht geladen werden")
            }
        }

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = Self.backgroundColor
        webView.scrollView.backgroundColor = Self.backgroundColor
        // Gummiband-Scrollen (bounces) ist gewünscht; damit dabei nie ein falsch
        // eingefärbter Bereich unterhalb des Inhalts sichtbar wird, sorgt layout-fix.js
        // zusätzlich dafür, dass html/body immer exakt die Bildschirmhöhe ausfüllen.
        webView.scrollView.bounces = true
        webView.scrollView.alwaysBounceVertical = true
        if #available(iOS 15.4, *) {
            // Farbe, die WebKit unter dem Seiteninhalt zeigt (z.B. beim Laden oder in
            // Sicherheitsabstands-Bereichen) – verhindert zuverlässiger als nur
            // backgroundColor/scrollView.backgroundColor einen schwarzen Blitzer.
            webView.underPageBackgroundColor = Self.backgroundColor
        }
        #if DEBUG
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        #endif

        // Eigene Pull-to-Refresh-Geste statt UIRefreshControl: die Seite bleibt dadurch
        // fix (kein Scrollen/Bounce nötig), reagiert aber trotzdem auf ein Herunterziehen
        // ganz oben, um Standort und Wetterdaten neu zu laden.
        let pullGesture = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePull(_:)))
        pullGesture.delegate = context.coordinator
        webView.scrollView.addGestureRecognizer(pullGesture)

        context.coordinator.webView = webView
        context.coordinator.locationBridge.attach(webView: webView)
        context.coordinator.nativeGeocoder.attach(webView: webView)

        if let htmlURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") {
            let readAccessRoot = htmlURL.deletingLastPathComponent()
            webView.loadFileURL(htmlURL, allowingReadAccessTo: readAccessRoot)
        } else {
            diagnostics.log(.error, source: "Bundle", "index.html nicht im App-Bundle gefunden")
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, UIGestureRecognizerDelegate {
        let diagnostics: DiagnosticsLog
        let refreshState: RefreshState
        let locationBridge: LocationBridge
        let nativeGeocoder: NativeGeocoder
        weak var webView: WKWebView?

        private let pullThreshold: CGFloat = 110
        private var didTriggerRefresh = false

        init(diagnostics: DiagnosticsLog, refreshState: RefreshState) {
            self.diagnostics = diagnostics
            self.refreshState = refreshState
            self.locationBridge = LocationBridge(diagnostics: diagnostics)
            self.nativeGeocoder = NativeGeocoder(diagnostics: diagnostics)
            super.init()
            // Standort und Wetter sollen bei jedem Öffnen/Wiederaufnehmen der App neu
            // geladen werden, nicht nur beim allerersten kalten Start der WebView.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleAppDidBecomeActive),
                name: UIApplication.didBecomeActiveNotification,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func handleAppDidBecomeActive() {
            triggerRefresh()
        }

        // MARK: Pull-to-refresh – lädt Standort und Wetterdaten neu (ruft die bereits
        // vorhandenen globalen Funktionen der Seite auf, ohne index.html anzufassen).

        @objc func handlePull(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let translationY = gesture.translation(in: view).y

            switch gesture.state {
            case .changed:
                if !didTriggerRefresh && translationY > pullThreshold {
                    didTriggerRefresh = true
                    triggerRefresh()
                }
            case .ended, .cancelled:
                didTriggerRefresh = false
            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        private func triggerRefresh() {
            DispatchQueue.main.async { self.refreshState.isRefreshing = true }
            webView?.evaluateJavaScript(
                "window.requestGeo && window.requestGeo(); window.loadMeteoSchweizData && window.loadMeteoSchweizData();",
                completionHandler: nil
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                self?.refreshState.isRefreshing = false
            }
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "geoBridge":
                guard let body = message.body as? [String: Any],
                      let type = body["type"] as? String,
                      let id = body["id"] as? Int else { return }
                switch type {
                case "getCurrentPosition", "watchPosition":
                    locationBridge.handleRequest(id: id)
                case "clearWatch":
                    locationBridge.clearWatch(id: id)
                default:
                    break
                }
            case "geocodeBridge":
                guard let body = message.body as? [String: Any],
                      let id = body["id"] as? Int,
                      let url = body["url"] as? String else { return }
                nativeGeocoder.handle(id: id, urlString: url)
            case "diagBridge":
                if let dict = message.body as? [String: Any], dict["type"] as? String == "success" {
                    diagnostics.reportSuccess()
                } else if let text = message.body as? String {
                    diagnostics.log(.error, source: "JavaScript", text)
                }
            default:
                break
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            diagnostics.log(.error, source: "WebView", "Laden fehlgeschlagen: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            diagnostics.log(.error, source: "WebView", "Seite konnte nicht geladen werden: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(.performDefaultHandling, nil)
        }

        // MARK: WKUIDelegate – öffnet Links, die _blank/neues Fenster verlangen, im selben WebView

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}
