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
    func changed() { stamp += 1 }
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
            if lock.enabled && lock.locked && api.loggedIn { LockView() }
            if let t = toast.text {
                VStack {
                    Spacer()
                    Text(t).font(Theme.font(.subheadline, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color.black.opacity(0.82), in: Capsule())
                        .padding(.bottom, 96)
                }
                .transition(.opacity).allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast.text)
        .tint(Theme.accent)
        .fontDesign(.rounded)
        .onChange(of: phase) { _, p in
            if p == .background && lock.enabled { lock.locked = true }
            if p == .active && lock.enabled && lock.locked && api.loggedIn { lock.unlock() }
        }
        .onAppear { if lock.enabled && lock.locked && api.loggedIn { lock.unlock() } }
    }
}

struct LockView: View {
    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 18) {
                Image("Logo").resizable().frame(width: 84, height: 84)
                Button { Lock.shared.unlock() } label: { Label("Lås op", systemImage: "faceid").font(Theme.font(.headline)) }
                    .buttonStyle(.borderedProminent)
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
            VStack(spacing: 22) {
                Spacer()
                Image("Logo").resizable().frame(width: 96, height: 96)
                VStack(spacing: 6) {
                    Text("Kaneo ACT").font(Theme.font(.largeTitle, .bold)).foregroundStyle(Theme.ink)
                    Text("Beslutninger, mail, Neo og bilag.").font(Theme.font(.subheadline)).foregroundStyle(Theme.sec)
                }
                Spacer()
                if let error { ErrorLine(text: error).padding(.horizontal) }
                Button {
                    busy = true; error = nil
                    Task {
                        do { try await web.login(); Push.shared.ask() }
                        catch let e as APIError { error = e.message }
                        catch {
                            let ns = error as NSError
                            if !(ns.domain == ASWebAuthenticationSessionErrorDomain && ns.code == 1) { self.error = error.localizedDescription }
                        }
                        busy = false
                    }
                } label: {
                    HStack { if busy { ProgressView().tint(.white) }; Text("Log ind med Kaneo").font(Theme.font(.headline)) }
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(Theme.brand)
                .disabled(busy)
                .padding(.horizontal, 24)
                Text("Kun for ACT-admins.").font(Theme.font(.caption)).foregroundStyle(Theme.dim).padding(.bottom, 24)
            }
        }
    }
}

struct MainTabs: View {
    @StateObject private var router = Router.shared
    @StateObject private var store = Store.shared

    var body: some View {
        TabView(selection: $router.tab) {
            TodayView().tabItem { Label("I dag", systemImage: "sun.max") }.tag(Tab.idag)
            DecisionsView().tabItem { Label("Beslutninger", systemImage: "checkmark.seal") }.tag(Tab.beslut)
                .badge(store.decisions.count)
            MailView().tabItem { Label("Mail", systemImage: "envelope") }.tag(Tab.mail)
                .badge(store.mailOpen)
            NeoView().tabItem { Label("Neo", systemImage: "sparkles") }.tag(Tab.neo)
            MoreView().tabItem { Label("Mere", systemImage: "ellipsis.circle") }.tag(Tab.mere)
        }
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
        do {
            async let o = API.shared.get("api/overblik")
            async let a = API.shared.get("api/alle")
            overblik = try await o; alle = try await a.array
            error = nil
        } catch { self.error = error.localizedDescription }
        loaded = true
    }

    func drop(_ id: String) {
        guard case .obj(var o) = overblik else { return }
        o["beslutninger"] = .arr(decisions.filter { $0["id"].text != id })
        overblik = .obj(o)
    }
}
