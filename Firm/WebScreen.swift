import SwiftUI
import WebKit

struct WebScreen: UIViewRepresentable {
    let holder: WebHolder
    func makeCoordinator() -> Bridge { Bridge() }
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "haptic")
        cfg.allowsInlineMediaPlayback = true
        cfg.websiteDataStore = .default()      // cookies persist: the session survives relaunch
        let js = "window.FIRM_NATIVE = true; document.documentElement.classList.add('native');"
        cfg.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.customUserAgent = (web.value(forKey: "userAgent") as? String ?? "") + " FirmApp/1.1"
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isOpaque = false; web.backgroundColor = .systemBackground
        web.allowsBackForwardNavigationGestures = false
        web.load(URLRequest(url: URL(string: "https://getstubbie.com/dashboard/app/")!))
        holder.view = web
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Bridge: NSObject, WKScriptMessageHandler {
        let light = UIImpactFeedbackGenerator(style: .light)
        let medium = UIImpactFeedbackGenerator(style: .medium)
        let select = UISelectionFeedbackGenerator()
        let notify = UINotificationFeedbackGenerator()
        override init() { super.init(); light.prepare(); select.prepare() }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            switch (m.body as? String) ?? "light" {
            case "select":  select.selectionChanged(); select.prepare()
            case "medium":  medium.impactOccurred()
            case "success": notify.notificationOccurred(.success)
            case "error":   notify.notificationOccurred(.error)
            default:        light.impactOccurred(); light.prepare()
            }
        }
    }
}
