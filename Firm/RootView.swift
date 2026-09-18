import SwiftUI
import LocalAuthentication
import UserNotifications

struct RootView: View {
    @StateObject private var store = Store()
    @State private var locked = true
    @State private var tab = "today"
    @State private var chatPath = NavigationPath()
    @AppStorage("theme") private var theme = "system"
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TabView(selection: $tab) {
            Tab("Today", systemImage: "house.fill", value: "today") { nav { TodayView() } }
            Tab("Team", systemImage: "person.2.fill", value: "team") { nav { TeamView() } }
            Tab("Chat", systemImage: "bubble.left.and.bubble.right.fill", value: "chat") {
                nav(path: $chatPath) { ChatsView() }
            }
            Tab("Business", systemImage: "chart.line.uptrend.xyaxis", value: "business") { nav { BusinessView() } }
            Tab("Manage", systemImage: "gearshape.fill", value: "manage") { nav { ManageView() } }
        }
        .environmentObject(store)
        .preferredColorScheme(theme == "light" ? .light : theme == "dark" ? .dark : nil)
        .task { await store.refresh() }
        .overlay { if store.needsApproval && !locked { ApproveScreen(code: store.pairingCode) } }
        .overlay { if locked { LockScreen(unlock: authenticate) } }
        .task(id: store.needsApproval) {
            while store.needsApproval { try? await Task.sleep(for: .seconds(3)); await store.refresh() }
        }
        .onAppear(perform: authenticate)
        .onChange(of: phase) { _, p in
            if p == .background { locked = true }
            else if p == .active { if locked { authenticate() } else { Task { await store.refresh() } } }
        }
        .onChange(of: tab) { _, _ in UISelectionFeedbackGenerator().selectionChanged() }
        // A tapped alert lands where the thing happened.
        .onReceive(NotificationCenter.default.publisher(for: PushTarget.open)) { note in
            guard let raw = note.userInfo?["url"] as? String else { return }
            let route = PushRoute(raw)
            if let room = route.room {
                tab = "chat"
                chatPath.append(RoomRef(id: room))
            } else if let t = route.tab, ["today", "team", "chat", "business", "manage"].contains(t) {
                tab = t
            }
            Task { await store.refresh() }
        }
        // Tapping the widget opens Today.
        .onOpenURL { url in
            if url.scheme == "firm" { tab = url.host ?? "today"; Task { await store.refresh() } }
        }
        // The badge is cleared by looking, not by guessing.
        .onChange(of: phase) { _, p in
            if p == .active { UNUserNotificationCenter.current().setBadgeCount(0) }
        }
    }

    // one navigation stack per tab, with every detail screen it can push
    @ViewBuilder private func nav<C: View>(path: Binding<NavigationPath>? = nil,
                                           @ViewBuilder _ content: () -> C) -> some View {
        NavigationStack(path: path ?? .constant(NavigationPath())) {
            content()
                .navigationDestination(for: Agent.self) { AgentDetail(a: $0) }
                .navigationDestination(for: Bet.self) { BetDetail(b: $0) }
                .navigationDestination(for: Product.self) { ProductDetail(p: $0) }
                .navigationDestination(for: Listing.self) { ListingDetail(l: $0) }
                .navigationDestination(for: Conversation.self) { ChatView(agent: $0.agent) }
                .navigationDestination(for: String.self) { key in
                    // exactly one String destination: two of them collide and SwiftUI
                    // silently pushes an empty view
                    switch key {
                    case "inbox": InboxView()
                    case "providers": ProvidersView()
                    case "log": LogView()
                    case "elliot": ElliotView()
                    default: EmptyView()
                    }
                }
                .navigationDestination(for: RoomRef.self) { RoomView(roomId: $0.id) }
                // the grey line that rides up the right edge while you scroll
                .scrollIndicators(.hidden)
                .refreshable { await store.refresh() }
        }
    }

    private func authenticate() {
        let ctx = LAContext(); ctx.localizedCancelTitle = "Cancel"
        var err: NSError?
        let policy: LAPolicy = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
            ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
        ctx.evaluatePolicy(policy, localizedReason: "Unlock The Firm") { ok, _ in
            DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.25)) { locked = !ok }
                if ok { Task { await store.refresh() } } }
        }
    }
}

struct ApproveScreen: View {
    let code: String?
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "iphone.badge.checkmark").font(.system(size: 50, weight: .light)).foregroundStyle(.secondary)
                Text("Approve this iPhone").font(.title2.weight(.semibold))
                Text("Open The Firm on the web, go to Manage → Approve a device, and enter this code.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 36)
                if let c = code {
                    Text(c.prefix(3) + " " + c.suffix(3))
                        .font(.system(size: 44, weight: .bold)).monospacedDigit().padding(.top, 8)
                    Text("Valid for 10 minutes").font(.caption).foregroundStyle(.tertiary)
                } else { ProgressView().padding(.top, 8) }
            }
        }
    }
}

struct LockScreen: View {
    var unlock: () -> Void
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "faceid").font(.system(size: 56, weight: .light))
                Text("The Firm").font(.title2.weight(.semibold))
                Button("Unlock", action: unlock).buttonStyle(.borderedProminent).padding(.top, 6)
            }
        }
    }
}
