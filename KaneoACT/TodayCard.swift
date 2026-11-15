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
            HStack(spacing: 2) {
                Image(systemName: up ? "arrow.up" : "arrow.down").font(.system(size: 10, weight: .bold))
                Text("\(abs(now - before))").font(Theme.mono(12, .medium))
            }
            .foregroundStyle(up ? Theme.ok : Theme.bad)
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

    var body: some View {
        Group {
            if !loaded { skeleton }
            else if failed || d.isNull { empty }
            else { content }
        }
        .padding(Theme.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Klaret i dag").font(Theme.sans(13, .medium)).foregroundStyle(Theme.sec)
                    HStack(alignment: .firstTextBaseline, spacing: Theme.s1) {
                        Text("\(d["klaret_i_dag"].int ?? 0)").font(Theme.mono(40, .medium)).monospacedDigit().foregroundStyle(Theme.ink)
                        Delta(now: d["klaret_i_dag"].int ?? 0, before: d["klaret_i_gaar"].int ?? 0)
                    }
                }
                Spacer()
                Text("7 dage").font(Theme.meta).foregroundStyle(Theme.dim)
            }
            Spark(points: series(d, "klaret", last: 7))
            HStack(alignment: .top, spacing: 0) {
                figure("\(d["mails_i_dag"].int ?? 0)", "Mails besvaret i dag", delta: (d["mails_i_dag"].int ?? 0, d["mails_i_gaar"].int ?? 0))
                figure(d["mrr"].int.map { daNumber(Double($0)) } ?? "-", "MRR, kr.")
                figure("\(d["bilag_klar"].int ?? 0)", "Bilag klar")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func figure(_ v: String, _ label: String, delta: (Int, Int)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(v).font(Theme.mono(16, .medium)).monospacedDigit().foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.7)
                if let delta { Delta(now: delta.0, before: delta.1) }
            }
            Text(label).font(Theme.meta).foregroundStyle(Theme.dim).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            RoundedRectangle(cornerRadius: 4).fill(Theme.raised).frame(width: 80, height: 10)
            RoundedRectangle(cornerRadius: 6).fill(Theme.raised).frame(width: 64, height: 34)
            RoundedRectangle(cornerRadius: 8).fill(Theme.raised).frame(height: 56)
            HStack { ForEach(0..<3, id: \.self) { _ in RoundedRectangle(cornerRadius: 4).fill(Theme.raised).frame(width: 70, height: 26); Spacer() } }
        }
        .accessibilityLabel("Henter dagens tal")
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
                block("Klaret", "Opgaver og beslutninger klaret pr. dag", series(d, "klaret", last: 30))
                block("Mails besvaret", "Svar sendt pr. dag", series(d, "mails", last: 30))
                block("Bilag registreret", "Købsbilag fanget eller uploadet pr. dag", series(d, "bilag", last: 30))
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
