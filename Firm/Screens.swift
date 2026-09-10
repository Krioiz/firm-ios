import SwiftUI
import Charts

// ---- Team ----------------------------------------------------------------------------
struct TeamView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let busy = store.agents.filter(\.working), idle = store.agents.filter { !$0.working }
        List {
            if !busy.isEmpty { Section("Working now · \(busy.count)") { ForEach(busy) { AgentRow(a: $0) } } }
            if !idle.isEmpty { Section("Idle · \(idle.count)") { ForEach(idle) { AgentRow(a: $0) } } }
        }
        .navigationTitle("Team")
        .overlay {
            if store.agents.isEmpty && store.loaded {
                ContentUnavailableView { Label("No agents", systemImage: "person.2") }
                description: { Text(store.lastError ?? "The server returned an empty list.") }
                actions: { Button("Try again") { Task { await store.refresh() } } }
            }
        }
    }
}
struct AgentRow: View {
    let a: Agent
    var body: some View {
        NavigationLink(value: a) {
            HStack(spacing: 12) {
                Avatar(agent: a)
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.display).font(.system(size: 17, weight: .medium))
                    Text(a.tidyRole).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(Fmt.money(a.spend)).font(.system(size: 16)).monospacedDigit().foregroundStyle(.secondary)
            }.padding(.vertical, 3)
        }
    }
}
struct AgentDetail: View {
    let a: Agent
    @EnvironmentObject var store: Store
    var body: some View {
        let bot = store.bots.first { $0.agent == a.id }
        List {
            Section {
                HStack(spacing: 14) {
                    Avatar(agent: a, size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(a.display).font(.system(size: 24, weight: .bold))
                        Text(a.tidyRole).font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 6)
            }
            Section {
                NavigationLink(value: Conversation(agent: a)) {
                    Label("Message \(a.display)", systemImage: "bubble.left.fill")
                }
            }
            Section {
                LabeledContent("Working") { Text(a.working ? "Yes" : "Idle").foregroundStyle(a.working ? .green : .secondary) }
                LabeledContent("Spent today") { Text(Fmt.money(a.spend)).monospacedDigit() }
                if let t = a.tasksDone { LabeledContent("Tasks done") { Text("\(t)") } }
                HStack {
                    Text("Discord bot")
                    Spacer()
                    if let b = bot {
                        Circle().fill(b.connected == true ? .green : .red).frame(width: 8, height: 8)
                        Text("@\(b.bot ?? "") · \(b.connected == true ? "connected" : "down")").foregroundStyle(.secondary)
                    } else { Text("none").foregroundStyle(.secondary) }
                }
            }
        }.navigationTitle(a.display).navigationBarTitleDisplayMode(.inline)
    }
}

// ---- Shop ----------------------------------------------------------------------------
struct ShopView: View {
    @EnvironmentObject var store: Store
    @State private var seg = 0
    var body: some View {
        let t = store.sales?.totals
        List {
            Section {
                Picker("", selection: $seg) { Text("Posters").tag(0); Text("Ideas").tag(1) }
                    .pickerStyle(.segmented).listRowInsets(.init(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
            if seg == 0 {
                if let posters = store.products?.posters, !posters.isEmpty {
                    Section { ProductGrid(items: posters) }.listRowInsets(.init(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
                Section("Listings") {
                    if let ls = store.sales?.listings, !ls.isEmpty {
                        ForEach(ls) { l in
                            NavigationLink(value: l) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(l.title ?? "").font(.system(size: 16, weight: .medium)).lineLimit(2)
                                    HStack(spacing: 8) {
                                        Pill(text: l.verdict ?? "", tint: verdictTint(l.verdict))
                                        Text("\(l.views ?? 0) views · \(l.favourites ?? 0) fav").font(.caption).foregroundStyle(.secondary)
                                        Spacer(); Text(Fmt.money(l.price)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 3)
                            }
                        }
                    } else { Text("Nothing listed yet").foregroundStyle(.secondary) }
                }
                if let t { Section { LabeledContent("Views") { Text("\(t.views ?? 0)") }
                    LabeledContent("Favourites") { Text("\(t.favourites ?? 0)") }
                    LabeledContent("Sold") { Text("\(t.sold ?? 0)") }
                    LabeledContent("Revenue") { Text(Fmt.money(t.revenue)).monospacedDigit() } } }
            } else {
                if let packs = store.products?.packs, !packs.isEmpty {
                    Section("Made, not listed") { ProductGrid(items: packs) }
                        .listRowInsets(.init(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
                let ideas = store.lab?.ideas ?? []
                ForEach(["ADVANCE", "HOLD", "DROP"], id: \.self) { st in
                    let group = ideas.filter { $0.status == st }
                    if !group.isEmpty {
                        Section(st == "ADVANCE" ? "Advancing · \(group.count)" : st == "HOLD" ? "On hold · \(group.count)" : "Dropped · \(group.count)") {
                            ForEach(group) { IdeaRow(i: $0) }
                        }
                    }
                }
            }
        }
    }
}
struct IdeaRow: View {
    let i: Idea
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(i.title ?? "").font(.system(size: 16, weight: .semibold))
                Spacer()
                Pill(text: i.status ?? "", tint: i.status == "ADVANCE" ? .green : i.status == "DROP" ? .red : .blue)
            }
            HStack(spacing: 12) {
                Text(Fmt.money(i.price_usd)).font(.caption).monospacedDigit()
                if let o = i.owner { Text("Owner · \(o)").font(.caption) }
                if let p = i.proposed_by { Text("By \(p)").font(.caption) }
            }.foregroundStyle(.secondary)
            if let th = i.thesis { Text(th).font(.system(size: 14)) }
            if let f = i.first_task { Text("First task — \(f)").font(.system(size: 13)).foregroundStyle(.secondary) }
            if let c = i.chair_why { Text("Matt — \(c)").font(.system(size: 13)).foregroundStyle(.secondary) }
        }.padding(.vertical, 4)
    }
}
struct ProductGrid: View {
    let items: [Product]
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(items) { p in
                NavigationLink(value: p) {
                    VStack(alignment: .leading, spacing: 0) {
                        if let u = p.images?.first, let url = URL(string: Store.base.replacingOccurrences(of: "/dashboard", with: "") + u) {
                            CachedImage(url: url).frame(height: 120).clipped()
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.title ?? "").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            Text(p.kind == "poster" ? (p.subtitle ?? "") : "\(p.pages ?? 0) pages")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if let s = p.state, s != "not listed" { Pill(text: s, tint: s == "active" ? .green : .blue).padding(8) }
                    }
                }.buttonStyle(.plain)
            }
        }
    }
}
struct ProductDetail: View {
    let p: Product
    var body: some View {
        List {
            if let imgs = p.images, !imgs.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(imgs, id: \.self) { u in
                                if let url = URL(string: Store.base.replacingOccurrences(of: "/dashboard", with: "") + u) {
                                    CachedImage(url: url, contentMode: .fit)
                                        .frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                            }
                        }.padding(.vertical, 6)
                    }
                }.listRowInsets(.init(top: 4, leading: 16, bottom: 4, trailing: 0))
            }
            Section {
                LabeledContent("State") { Text(p.state ?? "not listed") }
                if let pr = p.price { LabeledContent("Price") { Text(Fmt.money(pr)).monospacedDigit() } }
                if let v = p.views { LabeledContent("Views") { Text("\(v)") } }
                if let f = p.favourites { LabeledContent("Favourites") { Text("\(f)") } }
                if let v = p.verdict { LabeledContent("Verdict") { Text(v).foregroundStyle(verdictTint(v)) } }
            }
            if let t = p.etsy_title { Section("Listing title") { Text(t).font(.system(size: 15)) } }
            if let id = p.listing_id, let url = URL(string: "https://www.etsy.com/listing/\(id)") {
                Section { Link("Open on Etsy", destination: url) }
            }
        }.navigationTitle(p.title ?? "").navigationBarTitleDisplayMode(.inline)
    }
}
struct ListingDetail: View {
    let l: Listing
    var body: some View {
        List {
            Section { Text(l.title ?? "").font(.system(size: 16, weight: .medium)) }
            Section {
                LabeledContent("Verdict") { Text(l.verdict ?? "").foregroundStyle(verdictTint(l.verdict)) }
                if let f = l.what_to_fix { Text(f).font(.system(size: 14)).foregroundStyle(.secondary) }
                LabeledContent("Views") { Text("\(l.views ?? 0)") }
                LabeledContent("Favourites") { Text("\(l.favourites ?? 0)") }
                LabeledContent("Sold") { Text("\(l.sold ?? 0)") }
                LabeledContent("Price") { Text(Fmt.money(l.price)).monospacedDigit() }
            }
            if let id = l.listing_id, let url = URL(string: "https://www.etsy.com/listing/\(id)") {
                Section { Link("Open on Etsy", destination: url) }
            }
        }.navigationTitle("Listing").navigationBarTitleDisplayMode(.inline)
    }
}

// ---- Money ---------------------------------------------------------------------------
struct MoneyView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        List {
            if let l = store.luther, let start = l.starting {
                Section {
                    LutherHero(l: l, start: start, history: store.history, scrubbed: .constant(nil))
                        .listRowInsets(.init(top: 8, leading: 16, bottom: 8, trailing: 16)).listRowBackground(Color.clear)
                }
                Section {
                    LabeledContent("Cash") { Text(Fmt.money(l.cash)).monospacedDigit() }
                    LabeledContent("Won / lost") { Text("\(l.wins ?? 0) / \(l.losses ?? 0)") }
                    if let b = l.brier {
                        LabeledContent("Calibration") { Text(String(format: "%.3f", b)).monospacedDigit() }
                        if l.brier_ready != true {
                            Text("Needs about 30 resolved bets to mean anything — \(l.resolved_count ?? 0) so far.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if l.broke == true {
                    Section { Label("Out of money — he has stopped betting", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
                Section("Open bets") {
                    let open = l.open ?? []
                    if open.isEmpty { Text("No open bets").foregroundStyle(.secondary) }
                    else { ForEach(open) { b in NavigationLink(value: b) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(b.question ?? "").font(.system(size: 15, weight: .medium)).lineLimit(2)
                            HStack {
                                Text("\(b.outcome ?? "") · \(Int(b.shares ?? 0)) @ \(String(format: "%.2f", b.avg_price ?? 0))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(Fmt.signed(b.unrealised)).font(.caption).monospacedDigit()
                                    .foregroundStyle((b.unrealised ?? 0) >= 0 ? .green : .red)
                            }
                        }.padding(.vertical, 2)
                    } } }
                }
                Section("Settled") {
                    let s = l.settled ?? []
                    if s.isEmpty { Text("Nothing has resolved yet").foregroundStyle(.secondary) }
                    else { ForEach(s) { b in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(b.question ?? "").font(.system(size: 14)).lineLimit(2)
                                Text(b.result ?? "").font(.caption).foregroundStyle(b.result == "WON" ? .green : .secondary)
                            }
                            Spacer()
                            Text(Fmt.signed(b.pnl)).font(.caption).monospacedDigit()
                                .foregroundStyle((b.pnl ?? 0) >= 0 ? .green : .red)
                        }
                    } }
                }
            } else if store.loaded {
                ContentUnavailableView("Luther has not started", systemImage: "chart.line.uptrend.xyaxis")
            }
        }.navigationTitle("Luther")
    }
}
struct BetDetail: View {
    let b: Bet
    var body: some View {
        List {
            Section { Text(b.question ?? "").font(.system(size: 19, weight: .semibold)) }
            Section {
                LabeledContent("Position") { Text("\(b.outcome ?? "") · \(Int(b.shares ?? 0)) shares") }
                LabeledContent("Bought at") { Text(String(format: "%.2f", b.avg_price ?? 0)).monospacedDigit() }
                LabeledContent("He says") { Text("\(Int((b.probability ?? 0) * 100))%").monospacedDigit() }
                LabeledContent("Staked") { Text(Fmt.money(b.cost)).monospacedDigit() }
                LabeledContent("Worth now") { Text(Fmt.money(b.value_now)).monospacedDigit() }
                LabeledContent("Unrealised") { Text(Fmt.signed(b.unrealised)).monospacedDigit()
                    .foregroundStyle((b.unrealised ?? 0) >= 0 ? .green : .red) }
            }
            if let t = b.thesis { Section("Why he took it") { Text(t).font(.system(size: 15)) } }
            if let f = b.falsifier { Section("What would prove him wrong") { Text(f).font(.system(size: 15)) } }
            if let e = b.end_date { Section { LabeledContent("Resolves by") { Text(String(e.prefix(10))) } } }
        }.navigationTitle("Bet").navigationBarTitleDisplayMode(.inline)
    }
}
