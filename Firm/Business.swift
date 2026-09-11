import SwiftUI
import Charts

// Shop, Pipeline and Money are one tab: three views of the same business.
struct BusinessView: View {
    @EnvironmentObject var store: Store
    @AppStorage("bizSeg") private var seg = 0
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $seg) {
                Text("Shop").tag(0); Text("Pipeline").tag(1); Text("Money").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 8)
            .onChange(of: seg) { _, _ in UISelectionFeedbackGenerator().selectionChanged() }
            Group {
                switch seg {
                case 0: ShopView()
                case 1: PipelineView()
                default: MoneyView()
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(seg == 0 ? "Shop" : seg == 1 ? "Pipeline" : "Luther")
    }
}

/// AsyncImage re-downloads on every appearance. This keeps decoded images in memory so
/// scrolling the shop is instant after the first look.
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, UIImage>()
    init() { cache.totalCostLimit = 40 * 1024 * 1024; cache.countLimit = 60 }
    func image(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }
    func set(_ img: UIImage, _ url: URL) {
        // cost from the pixels, not by re-encoding: measuring a 14MB image by turning it
        // back into a JPEG was slower than drawing it
        let cost = Int(img.size.width * img.scale * img.size.height * img.scale * 4)
        cache.setObject(img, forKey: url as NSURL, cost: cost)
    }
}
struct CachedImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var maxWidth: CGFloat = 400
    @State private var img: UIImage? = nil
    var body: some View {
        ZStack {
            if let img {
                Image(uiImage: img).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(Color.secondary.opacity(0.10))
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .task(id: url) {
            guard let url else { return }
            // ask the server for a thumbnail rather than the 1600x2400 original: twenty of
            // those decoded at full size is ~375MB and iOS kills the app long before that
            let thumb = URL(string: "\(Store.base)/thumb?src=\(url.path)&w=\(Int(maxWidth))")
                ?? url
            if let hit = ImageCache.shared.image(thumb) { img = hit; return }
            var r = URLRequest(url: thumb); r.cachePolicy = .returnCacheDataElseLoad
            guard let (d, _) = try? await URLSession.shared.data(for: r), let ui = UIImage(data: d) else { return }
            ImageCache.shared.set(ui, thumb)
            await MainActor.run { img = ui }
        }
    }
}

// ---- Pipeline, redrawn as a flow you read downwards ----------------------------------
struct PipelineView: View {
    @EnvironmentObject var store: Store
    @State private var open: Set<String> = []
    var body: some View {
        let stages = store.pipeline?.stages ?? []
        let stuck = stages.flatMap { $0.cards ?? [] }.filter { $0.stuck == true }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Label("\(store.pipeline?.products ?? 0) in flight", systemImage: "shippingbox.fill")
                    if !stuck.isEmpty { Label("\(stuck.count) stuck", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.bottom, 12)

                ForEach(Array(stages.enumerated()), id: \.offset) { i, s in
                    StageBlock(index: i, last: i == stages.count - 1, stage: s,
                               expanded: open.contains(s.id),
                               toggle: {
                                   withAnimation(.spring(duration: 0.32)) {
                                       if open.contains(s.id) { open.remove(s.id) } else { open.insert(s.id) }
                                   }
                                   UISelectionFeedbackGenerator().selectionChanged()
                               })
                }
                Spacer(minLength: 40)
            }.padding(.top, 4)
        }
        .overlay {
            if stages.isEmpty && store.loaded {
                ContentUnavailableView("Nothing in the pipeline", systemImage: "arrow.triangle.branch")
            }
        }
        .onAppear { if open.isEmpty, let first = stages.first(where: { !($0.cards ?? []).isEmpty }) { open.insert(first.id) } }
    }
}

struct StageBlock: View {
    let index: Int; let last: Bool; let stage: Stage
    let expanded: Bool; let toggle: () -> Void
    private var cards: [Card] { stage.cards ?? [] }
    private var bad: Bool { cards.contains { $0.stuck == true } }
    private var name: String { String((stage.label ?? stage.key ?? "").split(separator: "—").first ?? "").trimmingCharacters(in: .whitespaces) }
    private var note: String {
        let parts = (stage.label ?? "").split(separator: "—")
        return parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
    }
    private var tint: Color { bad ? .red : cards.isEmpty ? .secondary : .accentColor }
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // the rail: a node and the line running to the next stage
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(cards.isEmpty ? Color.secondary.opacity(0.15) : tint)
                        .frame(width: 30, height: 30)
                    if cards.isEmpty {
                        Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 1.5).frame(width: 30, height: 30)
                    } else {
                        Text("\(cards.count)").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    }
                }
                if !last {
                    Rectangle().fill(cards.isEmpty ? Color.secondary.opacity(0.18) : tint.opacity(0.5))
                        .frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 30)

            VStack(alignment: .leading, spacing: 0) {
                Button(action: toggle) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                            if !note.isEmpty { Text(note).font(.system(size: 12)).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if !cards.isEmpty {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                    }
                }
                .buttonStyle(.plain).disabled(cards.isEmpty)

                if expanded && !cards.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(cards) { c in PipeCard(c: c) }
                    }.padding(.top, 10)
                } else if cards.isEmpty {
                    Text("Nothing here").font(.system(size: 13)).foregroundStyle(.tertiary).padding(.top, 3)
                }
                Spacer(minLength: last ? 0 : 22)
            }
        }
        .padding(.horizontal, 20)
    }
}

struct PipeCard: View {
    let c: Card
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(c.title ?? "").font(.system(size: 15, weight: .medium))
            HStack(spacing: 6) {
                if let h = c.holder, !h.isEmpty {
                    Text(h.prefix(1).uppercased() + h.dropFirst()).font(.system(size: 12, weight: .medium))
                }
                if let d = c.days_in_stage {
                    Text("· \(d) day\(d == 1 ? "" : "s") here").font(.system(size: 12))
                }
                Spacer()
            }.foregroundStyle(.secondary)
            if c.stuck == true { Pill(text: "Stuck", tint: .red) }
            else if let v = c.verdict { Pill(text: v, tint: .blue) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            if c.stuck == true {
                RoundedRectangle(cornerRadius: 2).fill(.red).frame(width: 3).padding(.vertical, 8).padding(.leading, 1)
            }
        }
    }
}
