import SwiftUI

// Tradster — the firm's trading book as a conversation. Its own app, its own icon, its own
// place on the home screen; nothing from The Firm's tabs. One screen: ask the book what we
// bought, sold, hold or closed, and get the coins back as cards with logo, side, entry -> now,
// basis points and the hourly price since entry. The text is the firm's own model's; every
// number on a card is plain code reading the paper books on the server.

@main
struct TradsterApp: App {
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
                NavigationStack { BookChatView() }
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

struct PairingView: View {
    let code: String?; let checking: Bool; let paired: Bool?
    let retry: () async -> Void
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 44, weight: .semibold)).foregroundStyle(Color.indigo)
            Text("Tradster").font(.system(size: 30, weight: .bold))
            if paired == nil {
                ProgressView()
            } else {
                Text("Godkend denne telefon i firmaets dashboard under Enheder.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 32)
                if let code {
                    Text(code).font(.system(size: 40, weight: .bold, design: .monospaced)).kerning(6)
                        .padding(.horizontal, 24).padding(.vertical, 14)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    Text("Ingen forbindelse til serveren.").foregroundStyle(.secondary)
                }
                Button { Task { await retry() } } label: {
                    HStack { if checking { ProgressView().tint(.white) }; Text("Prøv igen") }
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 28).padding(.vertical, 12)
                        .background(Color.indigo, in: Capsule())
                }.disabled(checking)
            }
            Spacer()
            Text("Papirhandler på Kraken. Ingen rigtige penge.").font(.footnote).foregroundStyle(.tertiary).padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}
