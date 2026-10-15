import SwiftUI

// Tradster — the firm's trading book as a conversation. Its own app, its own icon, its own
// place on the home screen; nothing from The Firm's tabs. One screen: ask the book what we
// bought, sold, hold or closed, and get the coins back as cards with logo, side, entry -> now,
// basis points and the hourly price since entry. The text is the firm's own model's; every
// number on a card is plain code reading the paper books on the server.

@main
struct TradsterApp: App {
    @UIApplicationDelegateAdaptor(Push.self) var push
    var body: some Scene {
        WindowGroup { TradsterRoot() }
    }
}

struct TradsterRoot: View {
    @State private var paired: Bool? = nil
    @State private var code: String? = nil
    @State private var checking = false

    var body: some View {
        Group {
            if paired == true {
                TradsterTabs()
            } else {
                PairingView(code: code, checking: checking, paired: paired) { await check() }
            }
        }
        .task { await check() }
    }

    /// The phone proves itself with its Keychain secret; the first time, the server hands back a
    /// pairing code that Marco approves in the dashboard. Nothing to type here.
    private func check() async {
        checking = true
        if await DeviceAuth.session() { paired = true }
        else {
            paired = false
            if code == nil { code = await DeviceAuth.requestCode() }
        }
        checking = false
    }
}

/// Three places along the bottom, on Liquid Glass (iOS 26 draws the bar itself; iOS 18 gets the
/// classic bar): Koda, the book live, and Inspiration. One BookChatModel for all of them.
struct TradsterTabs: View {
    enum Place: Hashable { case koda, bog, inspiration }
    @StateObject private var model = BookChatModel()
    @State private var place: Place = .koda
    var body: some View {
        tabs
            .tint(Theme.text)
            // "Spørg Koda" from anywhere lands in the chat.
            // Handled here, not in the chat: a tab that is not on screen may not be listening.
            .onReceive(NotificationCenter.default.publisher(for: AskKoda.note)) { n in
                if place != .koda { withAnimation(.snappy) { place = .koda } }
                if let q = n.userInfo?["q"] as? String, !model.sending { model.send(q) }
            }
            .onChange(of: place) { _, _ in Haptic.tap() }
    }
    @ViewBuilder private var tabs: some View {
        let t = TabView(selection: $place) {
            Tab("Koda", systemImage: "bubble.left.and.text.bubble.right", value: Place.koda) {
                NavigationStack { BookChatView(model: model) }
            }
            Tab("Bogen", systemImage: "chart.line.uptrend.xyaxis", value: Place.bog) {
                BookSheet(model: model, asTab: true)
            }
            Tab("Inspiration", systemImage: "sparkles", value: Place.inspiration) {
                InspirationView()
            }
        }
        if #available(iOS 26.0, *) { t.tabBarMinimizeBehavior(.onScrollDown) } else { t }
    }
}

struct PairingView: View {
    let code: String?; let checking: Bool; let paired: Bool?
    let retry: () async -> Void
    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer()
                Image("Logo").resizable().scaledToFit().frame(width: 110)
                Text("Tradster").font(.system(size: 34, weight: .regular, design: .serif)).foregroundStyle(Theme.text)
                if paired == nil {
                    ProgressView().tint(Theme.secondary)
                } else {
                    Text("Godkend denne telefon i firmaets dashboard under Enheder.")
                        .font(.system(size: 15)).multilineTextAlignment(.center).foregroundStyle(Theme.secondary).padding(.horizontal, 36)
                    if let code {
                        Text(code).font(.system(size: 40, weight: .semibold, design: .monospaced)).kerning(6).foregroundStyle(Theme.text)
                            .padding(.horizontal, 24).padding(.vertical, 14)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    } else {
                        Text("Ingen forbindelse til serveren.").foregroundStyle(Theme.secondary)
                    }
                    Button { Task { await retry() } } label: {
                        HStack { if checking { ProgressView().tint(Theme.bg) }; Text("Prøv igen") }
                            .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.bg)
                            .padding(.horizontal, 28).padding(.vertical, 12)
                            .background(Theme.accent, in: Capsule())
                    }.disabled(checking)
                }
                Spacer()
                Text("Papir på Kraken · ingen rigtige penge").font(.footnote).foregroundStyle(Theme.secondary.opacity(0.7)).padding(.bottom, 24)
            }
        }
        .preferredColorScheme(.dark)
    }
}
