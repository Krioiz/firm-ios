import SwiftUI
import UIKit

// The book, live. The server marks every leg to Kraken (GET /book/live, 3 s cache) and the phone asks
// every 4 seconds while a live view is on screen. Its own object: only the ticking numbers watch it,
// so a tick never re-renders the greeting, the composer or the thread.

struct LiveLeg: Codable, Hashable, Sendable, Identifiable {
    var id: String { "\(book ?? "")/\(symbol ?? "")" }
    let book: String?; let symbol: String?; let side: String?; let entry: Double?; let mark: Double?; let bp: Double?
}
struct LiveBookRow: Codable, Hashable, Sendable {
    let equity: Double?; let start: Double?; let net_bp: Double?; let net_kr: Double?; let closes_at: String?
}
struct LiveTotal: Codable, Hashable, Sendable { let now: Double?; let start: Double? }
struct LiveSnap: Codable, Sendable {
    let at: String?; let legs: [LiveLeg]?; let books: [String: LiveBookRow]?; let total: LiveTotal?
}

@MainActor final class LiveBook: ObservableObject {
    static let shared = LiveBook()
    @Published private(set) var snap: LiveSnap? = nil
    /// Which way each leg moved on the last tick (+1 / -1), for the short flash.
    @Published private(set) var moved: [String: Int] = [:]
    private var last = Date.distantPast
    private var inflight = false

    /// Runs as long as the calling view's .task lives; several views share the same ticks.
    func run() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(4))
        }
    }
    func refresh() async {
        guard !inflight, Date().timeIntervalSince(last) > 3, UIApplication.shared.applicationState == .active else { return }
        inflight = true; defer { inflight = false }
        var r = URLRequest(url: URL(string: "\(Tradster.base)/book/live")!)
        r.setValue("Tradster/1.0", forHTTPHeaderField: "User-Agent")
        r.cachePolicy = .reloadIgnoringLocalCacheData; r.timeoutInterval = 8
        guard let res = try? await URLSession.shared.data(for: r), (res.1 as? HTTPURLResponse)?.statusCode == 200,
              let s = await BookChatModel.decode(LiveSnap.self, res.0) else { return }
        last = Date()
        var m: [String: Int] = [:]
        let old = Dictionary((snap?.legs ?? []).map { ($0.id, $0.bp ?? 0) }, uniquingKeysWith: { a, _ in a })
        for l in s.legs ?? [] { if let o = old[l.id], let n = l.bp, abs(n - o) >= 0.5 { m[l.id] = n > o ? 1 : -1 } }
        if let o = snap?.total?.now, let n = s.total?.now, abs(n - o) >= 0.05 { m["total"] = n > o ? 1 : -1 }
        withAnimation(.snappy(duration: 0.35)) { snap = s; moved = m }
        BasketActivity.update(s)
        if !m.isEmpty {
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation(.easeOut(duration: 0.6)) { moved = [:] }
        }
    }
}

/// A small breathing dot: the number next to it is live.
struct LiveDot: View {
    @State private var on = false
    var body: some View {
        Circle().fill(Theme.up).frame(width: 6, height: 6)
            .opacity(on ? 1 : 0.35)
            .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever()) { on = true } }
            .accessibilityHidden(true)
    }
}

private func signedKr(_ v: Double) -> String { "\(v >= 0 ? "+" : "−")\(Tradster.kr(abs(v))) kr" }
private func pct(_ v: Double) -> String {
    String(format: "%@%.2f", v >= 0 ? "+" : "−", abs(v)).replacingOccurrences(of: ".", with: ",") + " %"
}

/// The greeting's line: what both paper books are worth right now, ticking.
struct LiveEquityLine: View {
    @ObservedObject var live = LiveBook.shared
    let fallback: (now: Double, start: Double)?
    var body: some View {
        let now = live.snap?.total?.now ?? fallback?.now, start = live.snap?.total?.start ?? fallback?.start
        if let now, let start {
            let diff = now - start, p = start > 0 ? diff / start * 100 : 0
            let col = diff >= 0 ? Theme.up : Theme.down
            let flash = live.moved["total"]
            HStack(spacing: 8) {
                if live.snap != nil { LiveDot() }
                Text("\(Tradster.kr(now)) kr").foregroundStyle(Theme.text)
                    .contentTransition(.numericText(value: now))
                Text("\(signedKr(diff)) · \(pct(p))").foregroundStyle(col)
                    .contentTransition(.numericText(value: diff))
            }
            .font(.system(size: 14, weight: .medium)).monospacedDigit()
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background((flash == 1 ? Theme.up : Theme.down).opacity(flash == nil ? 0 : 0.14), in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityHint("Åbner bogen")
        }
    }
}

/// The top of "Bogen lige nu": the basket's result if it closed now, then every leg ticking.
struct LiveBasket: View {
    @ObservedObject var live = LiveBook.shared
    let logos: [String: BookCard]
    var body: some View {
        if let s = live.snap {
            VStack(alignment: .leading, spacing: 14) {
                if let k = s.books?["kraken-1h"], let kr = k.net_kr {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            LiveDot()
                            Text("Momentum-kurven, hvis den lukkede nu").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        }
                        Text(signedKr(kr)).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(kr >= 0 ? Theme.up : Theme.down)
                            .contentTransition(.numericText(value: kr))
                        HStack(spacing: 6) {
                            if let bp = k.net_bp { Text("\(bp >= 0 ? "+" : "−")\(Int(abs(bp).rounded())) bp efter gebyr og funding") }
                            if let c = k.closes_at, let d = Tradster.date(c) {
                                let h = max(0, d.timeIntervalSinceNow / 3600)
                                Text("· lukker om \(Int(h.rounded())) t")
                            }
                        }
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary).monospacedDigit()
                    }
                }
                if s.books?["kraken-1h"]?.net_kr != nil { FollowButton(snap: s) }
                let legs = (s.legs ?? []).sorted { ($0.bp ?? -1e9) > ($1.bp ?? -1e9) }
                VStack(spacing: 0) {
                    ForEach(legs) { l in LiveLegRow(l: l, card: logos[l.symbol ?? ""], flash: live.moved[l.id]) }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }
}

struct LiveLegRow: View {
    let l: LiveLeg; let card: BookCard?; let flash: Int?
    var body: some View {
        let bp = l.bp ?? 0
        HStack(spacing: 12) {
            CoinLogo(url: card?.logo, fallback: card?.logo_fallback, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(l.symbol ?? "").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Text(l.side == "short" ? "Kort" : "Lang").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            Text(l.bp == nil ? "–" : pct(bp / 100))
                .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                .foregroundStyle(l.bp == nil ? Theme.secondary : (bp >= 0 ? Theme.up : Theme.down))
                .contentTransition(.numericText(value: bp))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background((flash == 1 ? Theme.up : Theme.down).opacity(flash == nil ? 0 : 0.18), in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}

/// "Følg på låseskærmen": the basket as a Live Activity, kept ticking by the server.
struct FollowButton: View {
    let snap: LiveSnap
    @State private var on = BasketActivity.current != nil
    var body: some View {
        Button {
            Haptic.tap()
            if on { BasketActivity.stop() } else { BasketActivity.start(snap) }
            withAnimation(.snappy) { on = BasketActivity.current != nil || !on }
        } label: {
            Label(on ? "Følges på låseskærmen" : "Følg på låseskærmen", systemImage: on ? "checkmark.circle.fill" : "lock.iphone")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(on ? Theme.up : Theme.text)
                .padding(.horizontal, 14).padding(.vertical, 9).modifier(Glass(interactive: true))
        }
        .buttonStyle(.plain)
        .disabled(!BasketActivity.enabled && !on)
    }
}
