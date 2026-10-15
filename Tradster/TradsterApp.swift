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
        .task { BasketActivity.observe(); await check() }
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

/// Three places, switched by a glass pill at the top (no tab bar: it fought the Claude-like design).
/// Hidden inside a conversation, where the top bar shows the room instead. One BookChatModel for all.
struct TradsterTabs: View {
    enum Place: String, Hashable, CaseIterable {
        case koda = "Koda", bog = "Bogen", inspiration = "Inspiration", penge = "Penge"
        var icon: String {
            switch self { case .koda: "bubble.left"; case .bog: "chart.line.uptrend.xyaxis"; case .inspiration: "sparkles"; case .penge: "creditcard" }
        }
    }
    @StateObject private var model = BookChatModel()
    @State private var place: Place = .koda
    @Namespace private var pill

    var body: some View {
        ZStack(alignment: .top) {
            Theme.bg.ignoresSafeArea()
            Group {
                switch place {
                case .koda: NavigationStack { BookChatView(model: model) }
                case .bog: BookSheet(model: model, asTab: true)
                case .inspiration: InspirationView()
                case .penge: EconomyView()
                }
            }
            .transition(.opacity)
            if place != .koda || model.messages.isEmpty {
                switcher.padding(.top, 6).transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy(duration: 0.25), value: place)
        .animation(.snappy(duration: 0.25), value: model.messages.isEmpty)
        // "Spørg Koda" from anywhere lands in the chat.
        .onReceive(NotificationCenter.default.publisher(for: AskKoda.note)) { n in
            if place != .koda { place = .koda }
            if let q = n.userInfo?["q"] as? String, !model.sending { model.send(q) }
        }
    }

    private var switcher: some View {
        HStack(spacing: 2) {
            ForEach(Place.allCases, id: \.self) { p in
                Button {
                    guard p != place else { return }
                    Haptic.tap(); Keyboard.hide(); place = p
                } label: {
                    // Four places do not fit as words between the two round buttons: the chosen one
                    // shows its name, the others only their icon.
                    HStack(spacing: 5) {
                        Image(systemName: p.icon).font(.system(size: 13, weight: .semibold))
                        if p == place { Text(p.rawValue).font(.system(size: 14, weight: .semibold)).lineLimit(1).fixedSize() }
                    }
                        .foregroundStyle(p == place ? Theme.bg : Theme.text.opacity(0.85))
                        .padding(.horizontal, p == place ? 13 : 11).frame(height: 34)
                        .background {
                            if p == place { Capsule().fill(Theme.text).matchedGeometryEffect(id: "sel", in: pill) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(p.rawValue)
                .accessibilityAddTraits(p == place ? .isSelected : [])
            }
        }
        .padding(4)
        .modifier(Glass())
        .frame(height: 44)
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
