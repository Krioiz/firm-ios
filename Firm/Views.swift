import SwiftUI
import Charts

// ---- shared pieces -------------------------------------------------------------------
struct Tile: View {
    let label: String; let value: String; var foot: String? = nil; var tint: Color = .blue
    var icon: String = "circle.fill"; var series: [Double]? = nil; var ring: (Int, Int)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30).background(tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).padding(.top, 10)
            Text(value).font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit().padding(.top, 2)
            if let foot { Text(foot).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).padding(.top, 4) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
        .padding(14)
        .overlay(alignment: .bottomTrailing) {
            if let s = series, s.count > 1 {
                let lo = s.min() ?? 0, hi = s.max() ?? 1, pad = max((hi - lo) * 0.15, 0.5)
                Chart(Array(s.enumerated()), id: \.offset) { i, v in
                    LineMark(x: .value("i", i), y: .value("v", v)).foregroundStyle(tint)
                        .interpolationMethod(.catmullRom).lineStyle(.init(lineWidth: 2, lineCap: .round))
                }
                .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
                .chartYScale(domain: (lo - pad)...(hi + pad))
                .frame(width: 64, height: 30).padding(12)
            } else if let (n, total) = ring {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 5)
                    Circle().trim(from: 0, to: total > 0 ? min(1, Double(n) / Double(total)) : 0)
                        .stroke(.green, style: .init(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                }.frame(width: 38, height: 38).padding(12)
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct Avatar: View {
    let agent: Agent; var size: CGFloat = 38
    var body: some View {
        Text(agent.display.prefix(1))
            .font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Color.agentHue(agent.id), Color.agentHue(agent.id).opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            .overlay(alignment: .bottomTrailing) {
                Circle().fill(agent.working ? .green : Color.secondary.opacity(0.4))
                    .frame(width: size * 0.3, height: size * 0.3)
                    .overlay(Circle().stroke(Color(.systemGroupedBackground), lineWidth: 2.5))
            }
    }
}

struct Pill: View {
    let text: String; var tint: Color = .secondary
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(tint.opacity(0.16), in: Capsule())
    }
}
func verdictTint(_ v: String?) -> Color {
    switch v { case "SELLING": return .green; case "NOT FOUND": return .orange
    case "NOT WANTED": return .red; case "STALLED": return .blue; default: return .secondary }
}

// ---- Today ---------------------------------------------------------------------------
struct TodayView: View {
    @EnvironmentObject var store: Store
    @State private var showAlerts = false
    @State private var scrubbed: Day? = nil
    var body: some View {
        let busy = store.agents.filter(\.working)
        let spend = store.agents.reduce(0) { $0 + ($1.spend ?? 0) }
        let t = store.sales?.totals
        let live = (store.sales?.listings ?? []).filter { $0.state == "active" }.count
        let d = scrubbed
        ScrollView {
            VStack(spacing: 0) {
                if !store.agents.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(store.agents) { a in
                                NavigationLink(value: a) {
                                    VStack(spacing: 6) {
                                        Avatar(agent: a, size: 46)
                                            .overlay(Circle().stroke(.green, lineWidth: a.working ? 2.5 : 0).padding(-3))
                                        Text(a.display).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                    }.frame(width: 54)
                                }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal, 20).padding(.vertical, 12)
                    }
                }
                if let l = store.luther, let start = l.starting {
                    LutherHero(l: l, start: start, history: store.history, scrubbed: $scrubbed)
                        .padding(.horizontal, 16).padding(.bottom, 14)
                }
                if store.inboxCount > 0 {
                    NavigationLink(value: "inbox") {
                        HStack(spacing: 12) {
                            Image(systemName: "tray.full.fill").font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white).frame(width: 32, height: 32)
                                .background(.orange, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(store.inboxCount) waiting on you").font(.system(size: 17, weight: .semibold))
                                Text("Ideas and work the agents cannot move without you")
                                    .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(14)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain).padding(.horizontal, 16).padding(.bottom, 10)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    Tile(label: d == nil ? "Spent today" : "Spent that day", value: Fmt.money(d?.spend ?? spend),
                         foot: spendFoot(spend), tint: .blue, icon: "dollarsign.circle.fill",
                         series: store.history.compactMap(\.spend))
                    Tile(label: d == nil ? "Working now" : "Working then", value: "\(d?.working ?? busy.count) / \(d?.agents ?? store.agents.count)",
                         foot: busy.isEmpty ? "Everyone idle" : busy.prefix(3).map(\.display).joined(separator: ", "),
                         tint: .green, icon: "bolt.fill", ring: (d?.working ?? busy.count, d?.agents ?? max(store.agents.count, 1)))
                    Tile(label: "Shop revenue", value: Fmt.money(d?.revenue ?? t?.revenue),
                         foot: (t?.sold ?? 0) > 0 ? "\(t?.sold ?? 0) sold" : "No sales yet", tint: .orange, icon: "bag.fill",
                         series: store.history.compactMap(\.revenue))
                    Tile(label: "Live listings", value: "\(d?.live ?? live)",
                         foot: (t?.views ?? 0) > 0 ? "\(t?.views ?? 0) views · \(t?.favourites ?? 0) favourites" : "Waiting for views",
                         tint: .purple, icon: "lightbulb.fill", series: store.history.compactMap { $0.views.map(Double.init) })
                }.padding(.horizontal, 16)
                Spacer(minLength: 90)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Today")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAlerts = true } label: {
                    Image(systemName: store.alerts.isEmpty ? "bell" : "bell.badge.fill")
                }
            }
        }
        .sheet(isPresented: $showAlerts) { AlertsView(alerts: store.alerts) }
    }
    private func spendFoot(_ today: Double) -> String {
        guard store.history.count >= 2, let y = store.history[store.history.count - 2].spend else { return "" }
        let d = today - y
        return d == 0 ? "Same as yesterday" : "\(d < 0 ? "▼" : "▲") \(Fmt.money(abs(d))) vs yesterday"
    }
}

struct LutherHero: View {
    let l: Luther; let start: Double; let history: [Day]
    @Binding var scrubbed: Day?
    @State private var sel: CurvePoint? = nil
    var body: some View {
        let pts = (l.curve ?? []).filter { $0.equity != nil }
        let up = (l.total_pnl ?? 0) >= 0
        VStack(alignment: .leading, spacing: 0) {
            Text("Luther · paper book").font(.system(size: 12, weight: .medium)).textCase(.uppercase)
                .kerning(0.6).foregroundStyle(.secondary)
            Text(Fmt.money(sel?.equity ?? l.equity)).font(.system(size: 40, weight: .heavy, design: .rounded))
                .monospacedDigit().padding(.top, 2)
            HStack(spacing: 10) {
                Pill(text: "\(up ? "▲" : "▼") \(Fmt.money(abs(l.total_pnl ?? 0))) (\(String(format: "%+.2f", l.total_pnl_pct ?? 0))%)", tint: up ? .green : .red)
                Text("\(l.open_count ?? 0) open · \(l.wins ?? 0)W \(l.losses ?? 0)L")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }.padding(.top, 6)
            if pts.count > 1 {
                // The Y range must be built from the data. An AreaMark fills to zero by
                // default, which put a $16 spread on a 0-1000 axis and drew a flat line.
                let vals = pts.compactMap(\.equity)
                let lo = min(vals.min() ?? start, start), hi = max(vals.max() ?? start, start)
                let pad = max((hi - lo) * 0.18, 1)
                let bottom = lo - pad, topY = hi + pad
                Chart {
                    ForEach(Array(pts.enumerated()), id: \.offset) { i, p in
                        AreaMark(x: .value("i", i), yStart: .value("b", bottom), yEnd: .value("v", p.equity ?? 0))
                            .foregroundStyle(LinearGradient(colors: [(up ? Color.green : .red).opacity(0.28), .clear], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("i", i), y: .value("v", p.equity ?? 0))
                            .foregroundStyle(up ? Color.green : .red)
                            .interpolationMethod(.catmullRom).lineStyle(.init(lineWidth: 2.4, lineCap: .round))
                    }
                    RuleMark(y: .value("start", start)).foregroundStyle(.secondary.opacity(0.35))
                        .lineStyle(.init(lineWidth: 0.8, dash: [3, 4]))
                    if let s = sel, let i = pts.firstIndex(of: s) {
                        RuleMark(x: .value("i", i)).foregroundStyle(.secondary.opacity(0.5)).lineStyle(.init(lineWidth: 1, dash: [2, 3]))
                        PointMark(x: .value("i", i), y: .value("v", s.equity ?? 0)).foregroundStyle(up ? Color.green : .red)
                    }
                }
                .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
                .chartYScale(domain: bottom...topY)
                .frame(height: 130).padding(.top, 10)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 6)
                                .onChanged { v in
                                    guard let plot = proxy.plotFrame else { return }
                                    let x = v.location.x - geo[plot].origin.x
                                    guard let raw: Double = proxy.value(atX: x) else { return }
                                    let i = max(0, min(pts.count - 1, Int(raw.rounded())))
                                    if pts[i] != sel {
                                        sel = pts[i]
                                        scrubbed = history.first { $0.date == String((pts[i].at ?? "").prefix(10)) }
                                        UISelectionFeedbackGenerator().selectionChanged()
                                    }
                                }
                                .onEnded { _ in sel = nil; scrubbed = nil })
                    }
                }
                if let s = sel {
                    Text("\(Fmt.day(s.at)) · \(Fmt.money(s.equity))")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.top, 2)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct AlertsView: View {
    let alerts: [Alert]
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if alerts.isEmpty {
                    ContentUnavailableView("Nothing yet", systemImage: "bell",
                        description: Text("When Matt or the system raises something, it lands here."))
                } else {
                    List(alerts) { a in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(a.title ?? "").font(.system(size: 15, weight: .semibold))
                            Text((a.body ?? "").replacingOccurrences(of: "**", with: ""))
                                .font(.system(size: 14)).foregroundStyle(.secondary)
                            Text(Fmt.when(a.at)).font(.caption2).foregroundStyle(.tertiary)
                        }.padding(.vertical, 3)
                    }
                }
            }
            .navigationTitle("Alerts").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
