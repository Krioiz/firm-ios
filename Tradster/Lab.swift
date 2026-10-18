import SwiftUI

// The Lab: what Koda's edge lab has tested, so Marco can follow it without asking. Read-only, numbers
// and titles only (GET /dashboard/book/edgelab/tests). Quiet like Kodaconomy: one number on top, one
// line under it, the three closest rules, the ten newest, and folded rows for the rest. A tap on a test
// shows its numbers and title; nothing more.

struct LabTest: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let titel: String?; let venue: String?; let dato: String?
    let netto_bp: Double?; let t: Double?; let halvdele: [Double?]?; let n: Double?; let dom: String?
}
struct LabForward: Codable, Hashable, Sendable, Identifiable {
    let id: String; let navn: String?; let start: String?; let status: String?
}
struct LabFeed: Codable, Sendable {
    var total: Int? = nil; var today_tests: Int? = nil; var today_candidates: Int? = nil; var queue: Int? = nil
    var tests: [LabTest] = []; var forward: [LabForward] = []
    enum CodingKeys: String, CodingKey { case total, today_tests, today_candidates, queue, tests, forward }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        total = try? c.decodeIfPresent(Int.self, forKey: .total)
        today_tests = try? c.decodeIfPresent(Int.self, forKey: .today_tests)
        today_candidates = try? c.decodeIfPresent(Int.self, forKey: .today_candidates)
        queue = try? c.decodeIfPresent(Int.self, forKey: .queue)
        tests = ((try? c.decodeIfPresent([Lossy<LabTest>].self, forKey: .tests)) ?? nil)?.compactMap(\.value) ?? []
        forward = ((try? c.decodeIfPresent([Lossy<LabForward>].self, forKey: .forward)) ?? nil)?.compactMap(\.value) ?? []
    }
}

@MainActor final class LabModel: ObservableObject {
    @Published var f: LabFeed? = Disk.load(LabFeed.self, "lab.json")
    @Published var loading = false
    func load() async {
        loading = f == nil; defer { loading = false }
        var r = URLRequest(url: URL(string: "\(Tradster.base)/book/edgelab/tests")!)
        r.timeoutInterval = 20; r.cachePolicy = .reloadIgnoringLocalCacheData
        r.setValue("Tradster/1.0", forHTTPHeaderField: "User-Agent")
        guard let res = try? await URLSession.shared.data(for: r), (res.1 as? HTTPURLResponse)?.statusCode == 200,
              let v = await BookChatModel.decode(LabFeed.self, res.0) else { return }
        withAnimation(.snappy) { f = v }
        Disk.save(v, "lab.json")
    }
}

private func bp(_ v: Double?) -> String {
    guard let v else { return "–" }
    return "\(v >= 0 ? "+" : "−")\(Int(abs(v).rounded()))"
}
private func num(_ v: Double?, _ digits: Int = 1) -> String {
    guard let v else { return "–" }
    return String(format: "%.\(digits)f", v).replacingOccurrences(of: ".", with: ",").replacingOccurrences(of: "-", with: "−")
}
private func domColor(_ d: String?) -> Color {
    switch d { case "Kandidat": Theme.up; case "Svag": Theme.accent; default: Theme.secondary }
}

struct LabView: View {
    @StateObject private var m = LabModel()
    @State private var open: Set<String> = []
    @State private var shown: LabTest? = nil

    private var tests: [LabTest] { m.f?.tests ?? [] }
    private var closest: [LabTest] {
        Array(tests.filter { $0.dom != "Død" }.sorted { ($0.netto_bp ?? -.infinity) > ($1.netto_bp ?? -.infinity) }.prefix(3))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Lab").font(.system(size: 34, weight: .regular, design: .serif)).foregroundStyle(Theme.text)
                    .padding(.top, 24)
                if let f = m.f { headline(f) }
                if !closest.isEmpty { section("Tættest på", closest) }
                if !tests.isEmpty { section("Seneste", Array(tests.prefix(10))) }
                VStack(spacing: 0) {
                    if let fw = m.f?.forward, !fw.isEmpty {
                        fold("fwd", title: "Fremad-spor", value: "\(fw.count)") { forward(fw) }
                    }
                    if !tests.isEmpty {
                        if !(m.f?.forward ?? []).isEmpty { divider }
                        fold("all", title: "Alle \(tests.count)", value: "") { VStack(spacing: 0) { ForEach(tests) { row($0) } } }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                if m.loading && m.f == nil { ProgressView().tint(Theme.secondary).frame(maxWidth: .infinity).padding(.top, 40) }
                Text("Kun test på gammel data. Intet her handler.")
                    .font(.footnote).foregroundStyle(Theme.secondary.opacity(0.6)).padding(.vertical, 12)
            }
            .padding(.horizontal, 16)
        }
        .background(Theme.bg)
        .refreshable { await m.load() }
        .task { await m.load() }
        .sheet(item: $shown) { LabTestDetail(t: $0) }
        .preferredColorScheme(.dark)
    }

    private func headline(_ f: LabFeed) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Testet i alt").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            Text("\(f.total ?? tests.count)").font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Theme.text)
                .contentTransition(.numericText(value: Double(f.total ?? 0)))
            Text("I dag: \(f.today_tests ?? 0) tests · \(f.today_candidates ?? 0) kandidater")
                .font(.system(size: 14)).monospacedDigit().foregroundStyle(Theme.secondary)
            if let q = f.queue, q > 0 {
                Text("\(q) i kø").font(.system(size: 14)).monospacedDigit().foregroundStyle(Theme.secondary.opacity(0.7))
            }
        }
    }

    private func section(_ title: String, _ items: [LabTest]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            VStack(spacing: 0) { ForEach(items) { row($0) } }
        }
    }

    /// One line: short title, venue under it, net bp coloured, verdict chip.
    private func row(_ t: LabTest) -> some View {
        Button { Haptic.tap(); shown = t } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.titel ?? t.id).font(.system(size: 15)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
                    Text(t.venue ?? "").font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(bp(t.netto_bp)).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    .foregroundStyle((t.netto_bp ?? 0) > 0 ? Theme.up : Theme.down)
                chip(t.dom)
            }
            .padding(.vertical, 8).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chip(_ d: String?) -> some View {
        Text(d ?? "–").font(.system(size: 11, weight: .semibold)).foregroundStyle(domColor(d))
            .frame(width: 62).padding(.vertical, 3).background(domColor(d).opacity(0.15), in: Capsule())
    }

    private func forward(_ fw: [LabForward]) -> some View {
        VStack(spacing: 0) {
            ForEach(fw) { g in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(g.navn ?? g.id).font(.system(size: 15)).foregroundStyle(Theme.text).lineLimit(1)
                        Text("Fra \(Tradster.when(g.start))").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Text(status(g.status)).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                .padding(.vertical, 7)
            }
        }
    }
    private func status(_ s: String?) -> String {
        switch s { case "registered": "Tæller"; case "passed": "Holder"; case "failed": "Holder ikke"; case let x?: x; default: "–" }
    }

    /// A folded row, as on Kodaconomy: title left, one value right, chevron.
    private func fold<C: View>(_ key: String, title: String, value: String, @ViewBuilder _ content: () -> C) -> some View {
        let isOpen = open.contains(key)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                Haptic.tap()
                withAnimation(.snappy) { if isOpen { open.remove(key) } else { open.insert(key) } }
            } label: {
                HStack(spacing: 10) {
                    Text(title).font(.system(size: 15)).foregroundStyle(Theme.text)
                    Spacer()
                    if !isOpen && !value.isEmpty { Text(value).font(.system(size: 14)).monospacedDigit().foregroundStyle(Theme.secondary) }
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, 16).padding(.vertical, 15).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen { content().padding(.horizontal, 16).padding(.bottom, 12) }
        }
    }
    private var divider: some View { Rectangle().fill(Theme.surface2).frame(height: 1).padding(.horizontal, 16) }
}

/// The numbers of one test and its title. Nothing more.
struct LabTestDetail: View {
    let t: LabTest
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(t.titel ?? t.id).font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                tile("Netto", bp(t.netto_bp) + " bp", (t.netto_bp ?? 0) > 0 ? Theme.up : Theme.down)
                tile("t", num(t.t), Theme.text)
            }
            HStack(spacing: 8) {
                let h = t.halvdele ?? []
                tile("Halvdele", h.count == 2 ? "\(bp(h[0])) / \(bp(h[1]))" : "–", Theme.text)
                tile("n", t.n.map { Tradster.kr($0) } ?? "–", Theme.text)
            }
            Spacer()
        }
        .padding(20).padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg)
        .presentationDetents([.height(300)])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
    private func tile(_ l: String, _ v: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(l).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
            Text(v).font(.system(size: 17, weight: .semibold)).monospacedDigit().foregroundStyle(c).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
