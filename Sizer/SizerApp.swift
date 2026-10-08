import SwiftUI

// Max Sizer — how many shares, from a risk budget and a stop.
//
// Native and self-contained on purpose. The arithmetic is four lines; wrapping a web page in a
// WKWebView would need a network, would need the dashboard passkey, and Apple rejects webview
// shells besides. Everything here works on a plane.

@main
struct SizerApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

enum Side: String, CaseIterable { case long = "Long", short = "Short" }

/// Everything the screen shows, derived in one place so no view can disagree with another.
struct Sizing {
    var account: Double
    var riskPct: Double
    var entry: Double
    var stop: Double
    var side: Side

    var budget: Double { max(0, account) * max(0, riskPct) / 100 }
    var perShare: Double { abs(entry - stop) }
    /// Rounded DOWN, always: the loss at the stop must never exceed the budget.
    var qty: Int { perShare > 0 ? Int((budget / perShare).rounded(.down)) : 0 }
    var cost: Double { Double(qty) * entry }
    var taken: Double { Double(qty) * perShare }
    var unused: Double { budget - taken }
    var stopDistPct: Double { entry > 0 ? perShare / entry * 100 : 0 }
    var weightPct: Double { account > 0 ? cost / account * 100 : 0 }

    private var dir: Double { side == .long ? 1 : -1 }
    func target(_ r: Double) -> Double { entry + dir * perShare * r }

    var filledIn: Bool { account > 0 && entry > 0 && stop > 0 }
    var backwards: Bool {
        guard filledIn else { return false }
        return side == .long ? stop > entry : stop < entry
    }
    var valid: Bool { filledIn && !backwards && entry != stop && qty > 0 }

    /// Said plainly, in the order a person would notice them.
    var notes: [(String, String, Bool)] {
        guard filledIn else { return [] }
        if entry == stop {
            return [("No risk", "Entry and stop are the same price, so there is nothing to size against.", true)]
        }
        var out: [(String, String, Bool)] = []
        if backwards {
            out.append(("Backwards",
                        side == .long ? "On a long the stop sits below the entry."
                                      : "On a short the stop sits above the entry.", true))
        }
        if qty == 0 && !backwards {
            out.append(("Too small",
                        "One share risks \(fmt(perShare)), more than the whole \(fmt0(budget)) budget.", true))
        }
        if qty > 0 && stopDistPct < 1 {
            out.append(("Tight",
                        "The stop is \(fmt2(stopDistPct))% from entry — inside a normal day's noise on most things.", false))
        }
        if qty > 0 && weightPct > 100 {
            out.append(("Leverage", "The position is \(fmt1(weightPct))% of the account, so this needs margin.", false))
        } else if qty > 0 && weightPct > 50 {
            out.append(("Large", "The position is \(fmt1(weightPct))% of the account. The risk is capped; a gap is not.", false))
        }
        if riskPct > 5 {
            out.append(("Heavy", "\(fmt1(riskPct))% of the account on one trade. Twenty losers in a row ends it.", false))
        }
        return out
    }
}

func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
func fmt1(_ v: Double) -> String { String(format: "%.1f", v) }
func fmt2(_ v: Double) -> String { String(format: "%.2f", v) }
func fmt0(_ v: Double) -> String {
    let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0
    return f.string(from: NSNumber(value: v)) ?? "\(Int(v))"
}

struct ContentView: View {
    // Remembered on this device only, so the app is not blank next time. Nothing leaves it.
    @AppStorage("account") private var account = ""
    @AppStorage("risk") private var risk = "1"
    @AppStorage("entry") private var entry = ""
    @AppStorage("stop") private var stop = ""
    @AppStorage("side") private var sideRaw = Side.long.rawValue
    @FocusState private var focused: Field?

    enum Field { case account, risk, entry, stop }

    private var s: Sizing {
        Sizing(account: Double(account) ?? 0, riskPct: Double(risk) ?? 0,
               entry: Double(entry) ?? 0, stop: Double(stop) ?? 0,
               side: Side(rawValue: sideRaw) ?? .long)
    }

    private let accent = Color(red: 0.12, green: 0.48, blue: 0.44)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    answer
                    ForEach(Array(s.notes.enumerated()), id: \.offset) { _, n in
                        note(tag: n.0, body: n.1, bad: n.2)
                    }
                    inputs
                    card("The trade") {
                        row("Risk budget", s.account > 0 ? fmt0(s.budget) : "—")
                        row("Risk actually taken", s.valid ? fmt0(s.taken) : "—")
                        row("Unused budget", s.valid ? fmt0(s.unused) : "—")
                        row("Stop distance", s.filledIn ? "\(fmt2(s.stopDistPct))%" : "—")
                        row("Risk per share", s.valid ? fmt(s.perShare) : "—")
                        row("Position as % of account", s.valid ? "\(fmt1(s.weightPct))%" : "—", last: true)
                    }
                    card("If it goes your way") {
                        row("1:1 target", s.valid ? fmt(s.target(1)) : "—")
                        row("2:1 target", s.valid ? fmt(s.target(2)) : "—")
                        row("3:1 target", s.valid ? fmt(s.target(3)) : "—", last: true)
                    }
                    Button("Clear everything") {
                        account = ""; entry = ""; stop = ""; risk = "1"; sideRaw = Side.long.rawValue
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 4)

                    Text("The quantity rounds down, so the loss at your stop is never more than the budget. "
                         + "Commission, spread and slippage are not included, and a gap through the stop can "
                         + "lose more than the figure shown.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
                .padding(16)
            }
            .navigationTitle("Max Sizer")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer(); Button("Done") { focused = nil }
                }
            }
        }
    }

    private var answer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(s.valid ? "\(s.qty)" : "—")
                .font(.system(size: 44, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent)
            Text(s.valid && s.qty == 1 ? "share" : "shares")
                .font(.subheadline.weight(.semibold)).foregroundStyle(accent)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(s.valid ? fmt0(s.cost) : "—")
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                Text("position size").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(accent.opacity(0.55)))
    }

    private var inputs: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                field("Account", text: $account, placeholder: "100000", focus: .account)
                field("Risk %", text: $risk, placeholder: "1", focus: .risk,
                      hint: s.account > 0 ? fmt0(s.budget) : nil)
            }
            HStack(spacing: 10) {
                field("Entry", text: $entry, placeholder: "100", focus: .entry)
                field("Stop", text: $stop, placeholder: "95", focus: .stop,
                      hint: s.filledIn ? "\(fmt2(s.stopDistPct))% away" : nil)
            }
            Picker("", selection: $sideRaw) {
                ForEach(Side.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String,
                       focus: Field, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold)).kerning(0.7).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .keyboardType(.decimalPad)
                .focused($focused, equals: focus)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .padding(.vertical, 11).padding(.horizontal, 12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 11))
            Text(hint ?? " ").font(.caption2.monospaced()).foregroundStyle(.secondary)
        }
    }

    private func note(tag: String, body: String, bad: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(tag.uppercased())
                .font(.caption2.weight(.bold)).kerning(0.5)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(bad ? Color.red : Color.orange, in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(.white)
            Text(body).font(.footnote).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((bad ? Color.red : Color.orange).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 11))
    }

    private func card(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold)).kerning(0.7).foregroundStyle(.secondary)
                .padding(.bottom, 6)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func row(_ label: String, _ value: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.system(.footnote, design: .monospaced).weight(.semibold))
            }
            .padding(.vertical, 8)
            if !last { Divider() }
        }
    }
}
