import SwiftUI
import WebKit
import LocalAuthentication

// The web dashboard inside a native shell: Face ID on the door, a real Liquid Glass
// tab bar, and a bridge for haptics. The page hides its own tab bar when it sees us.
struct RootView: View {
    @StateObject private var web = WebHolder()
    @State private var locked = true
    @State private var tab = "today"
    @Environment(\.scenePhase) private var phase
    private let tabs: [(String, String, String)] = [
        ("today", "Today", "house.fill"), ("team", "Team", "person.2.fill"), ("shop", "Shop", "bag.fill"),
        ("pipeline", "Pipeline", "arrow.triangle.branch"), ("money", "Money", "chart.line.uptrend.xyaxis"), ("manage", "Manage", "gearshape.fill")]

    var body: some View {
        ZStack(alignment: .bottom) {
            WebScreen(holder: web).ignoresSafeArea()
            GlassTabBar(tabs: tabs, selected: $tab) { key in
                web.view?.evaluateJavaScript("go('\(key)')", completionHandler: nil)
            }
            .padding(.horizontal, 16).padding(.bottom, 10)
            if locked { LockScreen(unlock: authenticate).transition(.opacity) }
        }
        .onAppear { authenticate(); Alerts.shared.start() }
        .onChange(of: phase) { p in if p == .background { locked = true; Alerts.shared.schedule() } else if p == .active { if locked { authenticate() }; Alerts.shared.refresh { } } }
    }

    private func authenticate() {
        let ctx = LAContext(); ctx.localizedCancelTitle = "Cancel"
        var err: NSError?
        let policy: LAPolicy = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
            ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
        ctx.evaluatePolicy(policy, localizedReason: "Unlock The Firm") { ok, _ in
            DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.25)) { locked = !ok } }
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
                Button("Unlock") { unlock() }.buttonStyle(.borderedProminent).padding(.top, 6)
            }
        }
    }
}

// Real Liquid Glass on iOS 26; the closest material below it.
struct GlassTabBar: View {
    let tabs: [(String, String, String)]
    @Binding var selected: String
    var onSelect: (String) -> Void
    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.0) { t in
                Button {
                    selected = t.0; onSelect(t.0)
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.2).font(.system(size: 20, weight: .medium))
                        Text(t.1).font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(selected == t.0 ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background {
                        if selected == t.0 { Capsule().fill(Color.primary.opacity(0.08)) }
                    }
                }.buttonStyle(.plain)
            }
        }
        .padding(6)
        .modifier(GlassCapsule())
    }
}

struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 16, y: 8)
        }
    }
}

final class WebHolder: ObservableObject { var view: WKWebView? }
