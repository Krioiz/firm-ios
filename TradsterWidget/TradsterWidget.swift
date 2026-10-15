import ActivityKit
import SwiftUI
import WidgetKit

// Tradster's Live Activity: the open basket, ticking on the lock screen and in the Dynamic Island.

private let up = Color(red: 0.498, green: 0.820, blue: 0.627)
private let down = Color(red: 0.941, green: 0.478, blue: 0.431)
private let ink = Color(red: 0.925, green: 0.910, blue: 0.885)
private let dim = Color(red: 0.600, green: 0.580, blue: 0.550)
private let ground = Color(red: 0.078, green: 0.074, blue: 0.070)

private func kr(_ v: Double) -> String {
    let f = NumberFormatter(); f.locale = Locale(identifier: "da_DK"); f.numberStyle = .decimal; f.maximumFractionDigits = 0
    let s = f.string(from: NSNumber(value: abs(v).rounded())) ?? "\(Int(abs(v).rounded()))"
    return "\(v >= 0 ? "+" : "−")\(s) kr"
}
private func pct(_ bp: Double) -> String {
    String(format: "%@%.1f", bp >= 0 ? "+" : "−", abs(bp) / 100).replacingOccurrences(of: ".", with: ",") + " %"
}
private func col(_ v: Double) -> Color { v >= 0 ? up : down }

@main
struct TradsterWidgets: WidgetBundle {
    var body: some Widget { BasketLiveActivity() }
}

struct BasketLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BasketAttributes.self) { ctx in
            LockScreen(a: ctx.attributes, s: ctx.state)
                .activityBackgroundTint(ground.opacity(0.92))
                .activitySystemActionForegroundColor(ink)
        } dynamicIsland: { ctx in
            let s = ctx.state, a = ctx.attributes
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.title).font(.caption).foregroundStyle(dim)
                        Text(kr(s.netKr)).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(col(s.netKr))
                            .contentTransition(.numericText(value: s.netKr))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("lukker om").font(.caption).foregroundStyle(dim)
                        Text(timerInterval: Date()...max(Date(), Date(timeIntervalSince1970: a.closesAt)), countsDown: true)
                            .font(.callout.weight(.medium)).monospacedDigit().foregroundStyle(ink).multilineTextAlignment(.trailing)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        leg("Bedst", s.best, s.bestBp)
                        Spacer()
                        Text("\(s.netBp >= 0 ? "+" : "−")\(Int(abs(s.netBp).rounded())) bp").font(.caption).monospacedDigit().foregroundStyle(dim)
                        Spacer()
                        leg("Værst", s.worst, s.worstBp)
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: "chart.line.uptrend.xyaxis").foregroundStyle(col(s.netKr))
            } compactTrailing: {
                Text(kr(s.netKr)).font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(col(s.netKr))
                    .contentTransition(.numericText(value: s.netKr))
            } minimal: {
                Image(systemName: s.netKr >= 0 ? "arrow.up.right" : "arrow.down.right").foregroundStyle(col(s.netKr))
            }
            .keylineTint(col(s.netKr))
        }
    }
    private func leg(_ label: String, _ sym: String, _ bp: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(dim)
            HStack(spacing: 4) {
                Text(sym).font(.caption.weight(.semibold)).foregroundStyle(ink)
                Text(pct(bp)).font(.caption).monospacedDigit().foregroundStyle(col(bp))
            }
        }
    }
}

struct LockScreen: View {
    let a: BasketAttributes; let s: BasketAttributes.ContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tradster · \(a.title)").font(.footnote.weight(.medium)).foregroundStyle(dim)
                Spacer()
                Text("papir").font(.caption2.weight(.semibold)).foregroundStyle(dim)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(dim.opacity(0.18), in: Capsule())
            }
            HStack(alignment: .firstTextBaseline) {
                Text(kr(s.netKr)).font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(col(s.netKr)).contentTransition(.numericText(value: s.netKr))
                Text("\(s.netBp >= 0 ? "+" : "−")\(Int(abs(s.netBp).rounded())) bp").font(.subheadline).monospacedDigit().foregroundStyle(dim)
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("lukker om").font(.caption2).foregroundStyle(dim)
                    Text(timerInterval: Date()...max(Date(), Date(timeIntervalSince1970: a.closesAt)), countsDown: true)
                        .font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(ink).multilineTextAlignment(.trailing)
                        .frame(maxWidth: 90, alignment: .trailing)
                }
            }
            HStack(spacing: 14) {
                Label { Text("\(s.best) \(pct(s.bestBp))").monospacedDigit() } icon: { Image(systemName: "arrow.up.right") }
                    .foregroundStyle(up)
                Label { Text("\(s.worst) \(pct(s.worstBp))").monospacedDigit() } icon: { Image(systemName: "arrow.down.right") }
                    .foregroundStyle(down)
                Spacer()
                Text(Date(timeIntervalSince1970: s.updated), style: .time).foregroundStyle(dim)
            }
            .font(.caption)
        }
        .padding(16)
    }
}
