import SwiftUI
import WebKit

struct WebScreen: UIViewRepresentable {
    let holder: WebHolder
    @Binding var showTabs: Bool
    func makeCoordinator() -> Bridge { Bridge(showTabs: $showTabs) }
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "haptic")
        cfg.userContentController.add(context.coordinator, name: "chrome")
        cfg.allowsInlineMediaPlayback = true
        cfg.websiteDataStore = .default()      // cookies persist: the session survives relaunch
        let js = "window.FIRM_NATIVE = true; document.documentElement.classList.add('native');"
        cfg.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.customUserAgent = (web.value(forKey: "userAgent") as? String ?? "") + " FirmApp/2.1"
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isOpaque = false; web.backgroundColor = .systemBackground
        web.allowsBackForwardNavigationGestures = false
        holder.view = web                     // RootView loads the page once the device has a session
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Bridge: NSObject, WKScriptMessageHandler {
        let showTabs: Binding<Bool>
        init(showTabs: Binding<Bool>) { self.showTabs = showTabs; super.init(); light.prepare(); select.prepare() }
        let light = UIImpactFeedbackGenerator(style: .light)
        let medium = UIImpactFeedbackGenerator(style: .medium)
        let select = UISelectionFeedbackGenerator()
        let notify = UINotificationFeedbackGenerator()
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            if m.name == "chrome" {
                let show = (m.body as? String) == "showTabs"
                DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.25)) { self.showTabs.wrappedValue = show } }
                return
            }
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
