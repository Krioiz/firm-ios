import SwiftUI
import Charts

// The one data element on "Til dig": a clean "I dag" card. One big number (tasks and decisions
// finished today), a thin soft 7-day curve with area fill and a marked end point, and three small
// figures on one line. Numbers come from GET /api/app/idag (ACT's own tables, MRR from Kaneo).
// Kaneo's call API only has 7- and 30-day totals, so calls are on the detail screen, not in a curve.
struct DayPoint: Identifiable {
    let date: Date
    let value: Int
    var id: Date { date }
}

func series(_ d: JSON, _ key: String, last n: Int) -> [DayPoint] {
    d["dage"].array.suffix(n).compactMap { x in x["dato"].date.map { DayPoint(date: $0, value: x[key].int ?? 0) } }
}

struct Delta: View {
    let now: Int
    let before: Int
    var body: some View {
        if now != before {
            let up = now > before
            HStack(spacing: 1) {
                Image(systemName: up ? "arrow.up" : "arrow.down").font(.system(size: 8, weight: .bold))
                Text("\(abs(now - before))").font(Theme.mono(10, .medium)).monospacedDigit()
            }
            .foregroundStyle((up ? Theme.ok : Theme.bad).opacity(0.85))
            .accessibilityLabel(up ? "\(now - before) flere end i går" : "\(before - now) færre end i går")
        }
    }
}

/// A soft area + line with the last point marked. Draws in once unless Reduce Motion is on.
struct Spark: View {
    let points: [DayPoint]
    var height: CGFloat = 56
    var showAxis = false
    @State private var shown: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        let maxV = max(points.map(\.value).max() ?? 0, 1)
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Dag", p.date), y: .value("Antal", p.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(colors: [Theme.tile.opacity(0.22), Theme.tile.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Dag", p.date), y: .value("Antal", p.value))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(Theme.tile)
            }
            if let last = points.last {
                PointMark(x: .value("Dag", last.date), y: .value("Antal", last.value))
                    .symbolSize(36).foregroundStyle(Theme.tile)
                PointMark(x: .value("Dag", last.date), y: .value("Antal", last.value))
                    .symbolSize(110).foregroundStyle(Theme.tile.opacity(0.18))
            }
        }
        .chartYScale(domain: 0...(Double(maxV) * 1.15))
        .chartXAxis(showAxis ? .automatic : .hidden)
        .chartYAxis(showAxis ? .automatic : .hidden)
        .chartLegend(.hidden)
        .frame(height: height)
        .mask(alignment: .leading) {
            GeometryReader { g in Rectangle().frame(width: g.size.width * shown) }
        }
        .onAppear {
            if still { shown = 1 } else { withAnimation(.easeOut(duration: 0.7)) { shown = 1 } }
        }
        .accessibilityElement()
        .accessibilityLabel("Kurve for de sidste \(points.count) dage")
        .accessibilityValue(points.map { "\($0.value)" }.joined(separator: ", "))
    }
}

struct TodayCard: View {
    let d: JSON
    let loaded: Bool
    let failed: Bool

    /// Zeros with the real shape: the skeleton is the card itself, redacted, so nothing jumps.
    private static let placeholder: JSON = {
        let days = (1...7).map { JSON.obj(["dato": .str("2026-01-0\($0)"), "klaret": .num(Double($0 % 3 + 1))]) }
        let zero = JSON.obj(Dictionary(uniqueKeysWithValues: Kategori.all.map { ($0.key, JSON.num(0)) }))
        return .obj(["klaret_i_dag": .num(0), "klaret_i_gaar": .num(0), "i_dag": zero, "i_gaar": zero, "dage": .arr(days)])
    }()

    var body: some View {
        Group {
            if loaded && (failed || d.isNull) { empty }
            else { content(loaded ? d : Self.placeholder).redacted(reason: loaded ? [] : .placeholder) }
        }
        .padding(Theme.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.line, lineWidth: 1))
        .animation(.easeOut(duration: 0.25), value: loaded)
    }

    private func content(_ d: JSON) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Det har systemet klaret i dag").font(Theme.sans(12, .medium)).foregroundStyle(Theme.dim)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(d["klaret_i_dag"].int ?? 0)").font(Theme.mono(44, .medium)).monospacedDigit().foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                Delta(now: d["klaret_i_dag"].int ?? 0, before: d["klaret_i_gaar"].int ?? 0)
                Spacer()
                Text("7 dage").font(Theme.sans(11, .medium)).foregroundStyle(Theme.dim)
            }
            .padding(.top, 2)
            Spark(points: series(d, "klaret", last: 7), height: 52)
                .padding(.top, Theme.s2)
            Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, Theme.s3)
            Grid(alignment: .leading, horizontalSpacing: Theme.s2, verticalSpacing: Theme.s3) {
                ForEach(0..<2, id: \.self) { r in
                    GridRow {
                        ForEach(Kategori.all[(r * 3)..<(r * 3 + 3)]) { k in
                            KategoriCell(k: k, now: d["i_dag"][k.key].int, before: d["i_gaar"][k.key].int)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Dagens tal kunne ikke hentes").font(Theme.rowTitle).foregroundStyle(Theme.ink)
            Text("Træk ned for at prøve igen.").font(Theme.meta).foregroundStyle(Theme.dim)
        }
    }
}

/// Tap on the card: the same numbers over 30 days.
struct TodayDetail: View {
    @ObservedObject private var store = Store.shared

    var body: some View {
        let d = store.idag
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s4) {
                block("I alt", "Alt det, systemet har klaret pr. dag", series(d, "klaret", last: 30))
                ForEach(Kategori.all) { k in block(k.label, k.forklaring, series(d, k.key, last: 30)) }
                VStack(alignment: .leading, spacing: Theme.s1) {
                    Text("Kunder og opkald").font(Theme.section).foregroundStyle(Theme.ink)
                    Rows {
                        KV(k: "MRR nu", v: d["mrr"].int.map { kr(Double($0)) } ?? "-")
                        ForEach(d["mrr_maaneder"].array.suffix(3), id: \.self) { m in
                            KV(k: "MRR " + monthName(m["maaned"].text), v: kr(m["mrr"].double))
                        }
                        KV(k: "Opkald Neo tog, 7 dage", v: d["opkald"]["d7"].int.map { "\($0)" } ?? "-")
                        KV(k: "Opkald Neo tog, 30 dage", v: d["opkald"]["d30"].int.map { "\($0)" } ?? "-")
                        KV(k: "Bookinger, 30 dage", v: d["opkald"]["bookinger30"].int.map { "\($0)" } ?? "-")
                        KV(k: "Bilag klar nu", v: "\(d["bilag_klar"].int ?? 0)")
                    }
                    Text("Opkald findes kun som 7 og 30 dage i Kaneo, ikke pr. dag.").font(Theme.meta).foregroundStyle(Theme.dim)
                }
            }
            .padding(Theme.s3)
        }
        .screen()
        .refreshable { await store.loadToday() }
        .navigationTitle("30 dage")
    }

    private func block(_ title: String, _ sub: String, _ pts: [DayPoint]) -> some View {
        let total = pts.map(\.value).reduce(0, +)
        return VStack(alignment: .leading, spacing: Theme.s1) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Theme.section).foregroundStyle(Theme.ink)
                Spacer()
                Text("\(total)").font(Theme.mono(20, .medium)).monospacedDigit().foregroundStyle(Theme.ink)
            }
            Text(sub).font(Theme.meta).foregroundStyle(Theme.dim)
            if pts.allSatisfy({ $0.value == 0 }) {
                Text("Intet de sidste 30 dage.").font(Theme.small).foregroundStyle(Theme.sec).padding(.vertical, Theme.s2)
            } else {
                Spark(points: pts, height: 120, showAxis: true)
            }
        }
        .card()
    }

    private func monthName(_ iso: String) -> String {
        guard let d = ACTDate.parse(iso) else { return iso }
        return d.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "da_DK")))
    }
}

/// The six things the system does, counted from actual events in ACT (see /api/app/idag).
struct Kategori: Identifiable {
    let key: String
    let label: String
    let forklaring: String
    let brand: String?
    let symbol: String
    var id: String { key }
    static let all: [Kategori] = [
        Kategori(key: "mails", label: "Mails besvaret", forklaring: "Svar sendt pr. dag", brand: "brand-gmail", symbol: "envelope"),
        Kategori(key: "bilag", label: "Bilag i Dinero", forklaring: "Kladder lagt i Dinero og bilag bogført pr. dag", brand: "brand-dinero", symbol: "doc.text"),
        Kategori(key: "dokumenter", label: "Fakturaer og kontrakter", forklaring: "Fakturaer lagt i Dinero og kontrakter sendt pr. dag", brand: nil, symbol: "signature"),
        Kategori(key: "opgaver", label: "Opgaver løst", forklaring: "Opgaver agenterne har gjort færdige pr. dag", brand: nil, symbol: "checkmark.circle"),
        Kategori(key: "leads", label: "Leads", forklaring: "Leads fundet og kontaktet pr. dag", brand: nil, symbol: "person.badge.plus"),
        Kategori(key: "beslutninger", label: "Beslutninger", forklaring: "Beslutninger godkendt, afvist eller besvaret pr. dag", brand: nil, symbol: "checkmark.seal"),
    ]
}

/// One cell of the breakdown: icon or logo, number, label. Bright when above 0, quiet when 0.
struct KategoriCell: View {
    let k: Kategori
    let now: Int?
    let before: Int?
    var body: some View {
        let n = now ?? 0
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                ZStack {
                    if let b = k.brand { Image(b).resizable().scaledToFit().frame(width: 16, height: 16) }
                    else { Image(systemName: k.symbol).font(.system(size: 13, weight: .regular)).foregroundStyle(Theme.sec) }
                }
                .frame(width: 18, height: 18)
                Text(now.map { "\($0)" } ?? "-").font(Theme.mono(17, .medium)).monospacedDigit().foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                if let before { Delta(now: n, before: before) }
            }
            Text(k.label).font(Theme.sans(11, .medium)).foregroundStyle(Theme.dim)
                .lineLimit(2, reservesSpace: true).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(n > 0 ? 1 : 0.38)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(k.label): \(n)")
    }
}
