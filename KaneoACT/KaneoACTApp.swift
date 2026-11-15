import SwiftUI
import UIKit
import UserNotifications
import LocalAuthentication
import AuthenticationServices

@main
struct KaneoACTApp: App {
    @UIApplicationDelegateAdaptor(Push.self) var push
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

enum Tab: Hashable { case idag, beslut, mail, neo, mere }

@MainActor final class Router: ObservableObject {
    static let shared = Router()
    @Published var tab: Tab = .idag
    /// Bumped whenever something changes on the server, so every tab reloads on its next appearance.
    @Published var stamp = 0
    /// Text to put in Neo's field when it opens with context ("Om mailen fra ...: ").
    @Published var neoDraft: String?
    func changed() { stamp += 1 }
    func askNeo(_ draft: String?) {
        if let draft { neoDraft = draft }
        tab = .neo
    }
}

// MARK: - Push (APNs)
// The phone's APNs token goes to ACT (POST /api/app/enhed) under the app's own bearer session. ACT
// only sends when Marco has put an APNs key in secrets/apns.env; until then the token just waits.
final class Push: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var shared: Push!
    private var pending: String?

    override init() { super.init(); Push.shared = self }

    func application(_ app: UIApplication, didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Asked after login, not at first launch: a permission prompt over the login screen reads as noise.
    func ask() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            if ok { DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() } }
        }
    }

    func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken t: Data) {
        pending = t.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in self.uploadPending() }
    }

    func application(_ app: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("[push] registration failed: %@", error.localizedDescription)
    }

    /// Development-signed builds carry embedded.mobileprovision and talk to the APNs sandbox.
    static var environment: String {
        Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil ? "development" : "production"
    }

    @MainActor func uploadPending() {
        guard let t = pending, API.shared.loggedIn else { return }
        Task {
            _ = try? await API.shared.send("api/app/enhed", ["token": t, "miljoe": Push.environment, "navn": UIDevice.current.name])
        }
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler h: @escaping (UNNotificationPresentationOptions) -> Void) {
        h([.banner, .sound, .list])
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler h: @escaping () -> Void) {
        let type = response.notification.request.content.userInfo["type"] as? String ?? ""
        Task { @MainActor in
            Router.shared.tab = ["mail", "mail3", "autosvar"].contains(type) ? .mail : type == "beslutning" ? .beslut : .idag
            Router.shared.changed()
        }
        h()
    }
}

// MARK: - Lock (optional Face ID)
@MainActor final class Lock: ObservableObject {
    static let shared = Lock()
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "faceid") } }
    @Published var locked: Bool

    init() {
        let on = UserDefaults.standard.bool(forKey: "faceid")
        enabled = on; locked = on
    }

    var available: Bool { LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) }

    func unlock() {
        let ctx = LAContext()
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Lås Kaneo ACT op") { ok, _ in
            Task { @MainActor in if ok { self.locked = false } }
        }
    }

    /// Turning it on proves the face first, so nobody locks themselves out by accident.
    func set(_ on: Bool) {
        guard on else { enabled = false; return }
        LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Slå Face ID-lås til") { ok, _ in
            Task { @MainActor in self.enabled = ok }
        }
    }
}

struct RootView: View {
    @StateObject private var api = API.shared
    @StateObject private var lock = Lock.shared
    @StateObject private var toast = Toast.shared
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ZStack {
            if !api.loggedIn { LoginView() }
            else { MainTabs() }
            // Covers content straight away when the app loses focus (app switcher, Control Center).
            if lock.enabled && api.loggedIn && (lock.locked || phase != .active) { LockView() }
            if let t = toast.text {
                VStack {
                    Spacer()
                    HStack(spacing: Theme.s2) {
                        Text(t).font(Theme.sans(14, .medium)).foregroundStyle(Theme.onAccent)
                        if let u = toast.undo {
                            Button { u(); toast.dismiss() } label: {
                                Text("Fortryd").font(Theme.sans(14, .semibold)).foregroundStyle(Theme.onAccent).underline()
                                    .frame(minHeight: 44)
                            }
                            .accessibilityHint("Fortryder handlingen")
                        }
                    }
                    .padding(.horizontal, Theme.s3).padding(.vertical, toast.undo == nil ? 10 : 0)
                    .background(Theme.accent, in: Capsule())
                    .padding(.bottom, 92)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(toast.undo != nil)
            }
        }
        .animation(.easeOut(duration: 0.18), value: toast.text)
        .tint(Theme.accent)
        .font(Theme.body)
        .onChange(of: phase) { _, p in
            if p == .background && lock.enabled { lock.locked = true }
            if p == .active && lock.enabled && lock.locked && api.loggedIn { lock.unlock() }
        }
        .onAppear { if lock.enabled && lock.locked && api.loggedIn { lock.unlock() } }
    }
}

struct LockView: View {
    @ObservedObject private var lock = Lock.shared
    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: Theme.s3) {
                KTile(size: 72)
                VStack(spacing: 4) {
                    Text("Kaneo ACT er låst").font(Theme.sans(20, .semibold)).foregroundStyle(Theme.ink)
                    Text("Lås op for at se beslutninger, mail og tal.").font(Theme.small).foregroundStyle(Theme.sec)
                }
                if lock.locked {
                    Button { lock.unlock() } label: { Label("Lås op", systemImage: "faceid") }
                        .buttonStyle(PillButton(kind: .primary, full: false)).padding(.top, Theme.s1)
                }
            }
        }
    }
}

struct LoginView: View {
    @State private var busy = false
    @State private var error: String?
    private let web = WebLogin()

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            // A soft grey glow behind the tile: light on a surface, not a gradient.
            RadialGradient(colors: [Theme.ink.opacity(0.06), Theme.ink.opacity(0.03), .clear], center: .init(x: 0.5, y: 0.3), startRadius: 0, endRadius: 320)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                KTile(size: 88)
                Text("Velkommen til Kaneo ACT").font(Theme.sans(26, .semibold)).foregroundStyle(Theme.ink)
                    .padding(.top, Theme.s4)
                Text("Log ind for at se, hvad der venter på dig i dag.").font(Theme.body).foregroundStyle(Theme.sec)
                    .multilineTextAlignment(.center).padding(.top, Theme.s1).padding(.horizontal, Theme.s4)
                Spacer()
                if let error { Banner(title: "Login gik ikke.", text: error, tone: .bad).padding(.horizontal, Theme.s4).padding(.bottom, Theme.s2) }
                Button {
                    busy = true; error = nil
                    Task {
                        do { try await web.login(); Haptic.approve(); Push.shared.ask() }
                        catch let e as APIError { error = e.message; Haptic.fail() }
                        catch {
                            let ns = error as NSError
                            if !(ns.domain == ASWebAuthenticationSessionErrorDomain && ns.code == 1) { self.error = error.localizedDescription }
                        }
                        busy = false
                    }
                } label: {
                    ZStack {
                        Text("Log ind med Kaneo").opacity(busy ? 0 : 1)
                        if busy { ProgressView().tint(Theme.onAccent) }
                    }
                }
                .buttonStyle(.primary)
                .disabled(busy)
                .padding(.horizontal, Theme.s4)
                Text("Kun for ACT-administratorer.").font(Theme.meta).foregroundStyle(Theme.dim)
                    .padding(.top, Theme.s2).padding(.bottom, Theme.s4)
            }
        }
    }
}

struct MainTabs: View {
    @StateObject private var router = Router.shared
    @StateObject private var store = Store.shared

    var body: some View {
        TabView(selection: $router.tab) {
            ToDigView().tabItem { Label("Til dig", systemImage: "house") }.tag(Tab.idag)
                .badge(store.items.count)
            DecisionsView().tabItem { Label("Beslutninger", systemImage: "checkmark.circle") }.tag(Tab.beslut)
                .badge(store.decisions.count)
            MailView().tabItem { Label("Mail", systemImage: "tray") }.tag(Tab.mail)
                .badge(store.mailOpen)
            NeoView().tabItem { Label("Neo", systemImage: "waveform") }.tag(Tab.neo)
            MoreView().tabItem { Label("Mere", systemImage: "person") }.tag(Tab.mere)
        }
        .tabBarMinimizeIfAvailable()

        .task { Push.shared.ask(); await store.load() }
        .onChange(of: router.stamp) { _, _ in Task { await store.load() } }
    }
}

/// /api/overblik, shared by I dag, Beslutninger, the badges and Neo's @-list.
@MainActor final class Store: ObservableObject {
    static let shared = Store()
    @Published var overblik: JSON = .null
    @Published var alle: [JSON] = []
    @Published var error: String?
    @Published var loaded = false

    var decisions: [JSON] { overblik["beslutninger"].array }
    var mailOpen: Int { overblik["mail"].int ?? 0 }

    func load() async {
        // Mail and bilag first, so the list and the badges are complete when overblik publishes.
        async let m: () = MailModel.shared.load()
        async let b: () = Store.bilagLoader.load()
        _ = await (m, b)
        do {
            async let o = API.shared.get("api/overblik")
            async let a = API.shared.get("api/alle")
            overblik = try await o; alle = try await a.array
            error = nil
        } catch { self.error = error.localizedDescription }
        loaded = true
        updateBadge()
    }

    func drop(_ id: String) {
        guard case .obj(var o) = overblik else { return }
        o["beslutninger"] = .arr(decisions.filter { $0["id"].text != id })
        overblik = .obj(o)
    }
}

extension View {
    /// The system tab bar minimises on scroll where iOS offers it (iOS 26); older iOS keeps it.
    @ViewBuilder func tabBarMinimizeIfAvailable() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { self.tabBarMinimizeBehavior(.onScrollDown) } else { self }
        #else
        self
        #endif
    }
}
