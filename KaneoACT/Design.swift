import SwiftUI
import UIKit

// Kaneo's iOS design language "Lys" (Kaneos hjerne: 13-design-og-brand.md, 34-mobilapps-detaljeret.md,
// 35-designregler-detaljeret.md). Grey surfaces with chroma 0, a near-black (light) or near-white
// (dark) accent, DM Sans everywhere and DM Mono for numbers. Colour only when it means something:
// green = done or running, amber = needs you, red = wrong or overdue, and only as text, chip or dot.
// The tile colour (Marco's choice for this app, 15 Nov 2026: flat Vipps orange #FE5C25 with the white K)
// belongs to the K tile only. The UI accent stays the grey-scale pill, which holds contrast in both
// themes; white text on orange would not.

extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255) }
    /// One token, designed per theme (not an inversion).
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { t in
            let h = t.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((h >> 16) & 0xff) / 255, green: CGFloat((h >> 8) & 0xff) / 255, blue: CGFloat(h & 0xff) / 255, alpha: 1)
        })
    }
}

enum Theme {
    // Surfaces
    static let bg = Color.dyn(0xfafafa, 0x0a0a0a)
    static let surface = Color.dyn(0xffffff, 0x121212)
    static let raised = Color.dyn(0xf3f3f3, 0x1a1a1a)          // pressed rows, secondary buttons, fields
    static let line = Color.dyn(0xe4e4e4, 0x1e1e1e)
    static let lineStrong = Color.dyn(0xd4d4d4, 0x303030)
    // Text
    static let ink = Color.dyn(0x171717, 0xfafafa)
    static let sec = Color.dyn(0x585858, 0xa3a3a3)
    static let dim = Color.dyn(0x6c6c6c, 0x868686)
    // Accent: a black pill in light, a white pill in dark
    static let accent = Color.dyn(0x171717, 0xeeeeee)
    static let onAccent = Color.dyn(0xfafafa, 0x0b0b0b)
    // Meaning
    static let ok = Color.dyn(0x1f8a4c, 0x4cc38a)
    static let warn = Color.dyn(0xa86d00, 0xe8a33d)
    static let bad = Color.dyn(0xc9302c, 0xf08a7e)
    static let badSolid = Color(hex: 0xc62f2a)
    // The app's tile colour, for the K tile only
    static let tile = Color(hex: 0xFE5C25)

    // Spacing scale 8 / 12 / 16 / 24
    static let s1: CGFloat = 8, s2: CGFloat = 12, s3: CGFloat = 16, s4: CGFloat = 24

    static func sans(_ size: CGFloat, _ w: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        let name = w == .semibold || w == .bold || w == .heavy ? "DMSans-SemiBold" : w == .medium ? "DMSans-Medium" : "DMSans-Regular"
        return .custom(name, size: size, relativeTo: style)
    }
    static func mono(_ size: CGFloat, _ w: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(w == .regular ? "DMMono-Regular" : "DMMono-Medium", size: size, relativeTo: style)
    }

    // Type scale (iOS sizes of the web scale)
    static let hero = sans(52, .semibold, relativeTo: .largeTitle)
    static let title = sans(24, .semibold, relativeTo: .title)
    static let section = sans(17, .semibold, relativeTo: .headline)
    static let cardTitle = sans(16, .semibold, relativeTo: .headline)
    static let rowTitle = sans(15, .medium, relativeTo: .body)
    static let body = sans(15, .regular, relativeTo: .body)
    static let small = sans(13, .regular, relativeTo: .subheadline)
    static let meta = sans(12, .regular, relativeTo: .footnote)
    static let tag = sans(11, .medium, relativeTo: .caption2)
    static let button = sans(15, .semibold, relativeTo: .body)
    static let code = mono(12, .regular, relativeTo: .footnote)

    /// Kept for the screens' older call sites: maps a system text style to the DM Sans scale.
    static func font(_ style: Font.TextStyle, _ weight: Font.Weight = .regular) -> Font {
        let size: CGFloat
        switch style {
        case .largeTitle: size = 32
        case .title: size = 26
        case .title2: size = 22
        case .title3: size = 19
        case .headline: size = 16
        case .subheadline: size = 14
        case .footnote: size = 13
        case .caption: size = 12
        case .caption2: size = 11
        default: size = 15
        }
        return sans(size, style == .headline && weight == .regular ? .semibold : weight, relativeTo: style)
    }
}

enum Haptic {
    static func approve() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func reject() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func fail() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

// MARK: - The K tile: white K on one flat colour, radius 28 %, no gradient
struct KTile: View {
    var size: CGFloat = 64
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Theme.tile)
            Image("KMark").resizable().renderingMode(.template).scaledToFit()
                .foregroundStyle(.white).frame(height: size * 0.5).offset(x: size * 0.01)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Kaneo")
    }
}

/// Neo is thinking: the K tile breathing softly in a grey glow. Still when Reduce Motion is on.
struct Orb: View {
    var size: CGFloat = 22
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var still
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Theme.ink.opacity(0.10), Theme.ink.opacity(0.04), .clear], center: .center, startRadius: 0, endRadius: size))
                .frame(width: size * 2, height: size * 2)
                .scaleEffect(on ? 1.0 : 0.8).opacity(on ? 1 : 0.5)
            KTile(size: size).scaleEffect(on ? 1.0 : 0.94)
        }
        .frame(width: size * 1.4, height: size * 1.4)
        .onAppear {
            guard !still else { on = true; return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { on = true }
        }
    }
}

// MARK: - Buttons
struct PillButton: ButtonStyle {
    enum Kind { case primary, secondary, danger }
    var kind: Kind = .primary
    var full = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.button)
            .lineLimit(1).minimumScaleFactor(0.85)
            .foregroundStyle(kind == .primary ? Theme.onAccent : kind == .danger ? Theme.bad : Theme.ink)
            .frame(maxWidth: full ? .infinity : nil, minHeight: 44)
            .padding(.horizontal, Theme.s3)
            .background(kind == .primary ? Theme.accent : Theme.raised, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
extension ButtonStyle where Self == PillButton {
    static var primary: PillButton { PillButton(kind: .primary) }
    static var secondary: PillButton { PillButton(kind: .secondary) }
    static var danger: PillButton { PillButton(kind: .danger) }
}

/// Press feedback for whole rows and cards.
struct Press: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Surfaces
struct CardBG: ViewModifier {
    var padding: CGFloat = Theme.s3
    func body(content: Content) -> some View {
        content.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line, lineWidth: 1))
            .shadow(color: Color.dyn(0x000000, 0x000000).opacity(0.04), radius: 3, y: 1)
    }
}
extension View {
    func card(_ padding: CGFloat = Theme.s3) -> some View { modifier(CardBG(padding: padding)) }
    /// A list row inside a List styled as one grey surface.
    func surfaceRow() -> some View {
        listRowBackground(Theme.surface).listRowSeparatorTint(Theme.line)
    }
    func screen() -> some View {
        scrollContentBackground(.hidden).background(Theme.bg.ignoresSafeArea())
    }
}

/// Rows in one surface, divided by hairlines (lists, not boxes in boxes).
struct Rows<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { subs in
                ForEach(Array(subs.enumerated()), id: \.offset) { i, v in
                    v.padding(.horizontal, Theme.s3).padding(.vertical, Theme.s2)
                    if i < subs.count - 1 { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, Theme.s3) }
                }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }
}

struct SectionHead: View {
    let title: String
    var link: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Theme.section).foregroundStyle(Theme.ink)
            Spacer()
            if let link, let action {
                Button(action: action) { Text(link + " ›").font(Theme.small).foregroundStyle(Theme.sec) }.buttonStyle(.plain)
            }
        }
        .padding(.top, Theme.s4).padding(.bottom, Theme.s1)
    }
}

// MARK: - Chips, dots, banners
enum Tone { case neutral, ok, warn, bad
    var color: Color { switch self { case .neutral: return Theme.sec; case .ok: return Theme.ok; case .warn: return Theme.warn; case .bad: return Theme.bad } }
}

struct Chip: View {
    let text: String
    var tone: Tone = .neutral
    var mono = false
    var body: some View {
        Text(text).font(mono ? Theme.mono(11, .medium) : Theme.tag).foregroundStyle(tone.color)
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tone.color.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(tone.color.opacity(0.12), lineWidth: 1))
    }
}
/// Old name, same chip.
struct Pill: View {
    let text: String
    var color: Color = Theme.sec
    var body: some View {
        Text(text).font(Theme.tag).foregroundStyle(color).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct Dot: View {
    var tone: Tone
    var body: some View { Circle().fill(tone.color).frame(width: 7, height: 7) }
}

/// Grey banner: a bold first sentence, then the explanation in muted text.
struct Banner: View {
    let title: String
    var text: String = ""
    var tone: Tone = .neutral
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.s1) {
            if tone != .neutral { Dot(tone: tone) }
            (Text(title).font(Theme.sans(14, .semibold)).foregroundColor(tone == .bad ? Theme.bad : Theme.ink)
             + Text(text.isEmpty ? "" : " " + text).font(Theme.small).foregroundColor(Theme.sec))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.s2)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ErrorLine: View {
    let text: String
    var body: some View { Banner(title: "Det gik ikke.", text: text, tone: .bad) }
}

// MARK: - States
/// Empty state: small icon in a grey glow, one title, one sentence, at most one action.
struct EmptyState: View {
    let icon: String
    let title: String
    let text: String
    var action: (String, () -> Void)? = nil
    var body: some View {
        VStack(spacing: Theme.s2) {
            ZStack {
                Circle().fill(RadialGradient(colors: [Theme.ink.opacity(0.08), Theme.ink.opacity(0.02), .clear], center: .center, startRadius: 0, endRadius: 40))
                    .frame(width: 80, height: 80)
                Image(systemName: icon).font(.system(size: 22, weight: .regular)).foregroundStyle(Theme.sec)
            }
            Text(title).font(Theme.sans(16, .semibold)).foregroundStyle(Theme.ink)
            Text(text).font(Theme.small).foregroundStyle(Theme.sec).multilineTextAlignment(.center).frame(maxWidth: 280)
            if let action {
                Button(action.0, action: action.1).buttonStyle(PillButton(kind: .secondary, full: false)).padding(.top, Theme.s1)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}

/// Skeleton rows with the same height as the real ones; no spinners on first load.
struct SkeletonRows: View {
    var count = 4
    var body: some View {
        Rows {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: Theme.s2) {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.raised).frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4).fill(Theme.raised).frame(width: 180, height: 12)
                        RoundedRectangle(cornerRadius: 4).fill(Theme.raised).frame(width: 120, height: 10)
                    }
                    Spacer()
                }
            }
        }
    }
}

// MARK: - Service logos
struct BrandIcon: View {
    let item: JSON
    var size: CGFloat = 32
    var body: some View {
        let b = Brands.of(item)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Theme.raised)
            if b?.key == "kaneo" || b?.key == "kaneosign" {
                KTile(size: size)
            } else if let b, let a = b.asset {
                if let tint = b.tint {
                    Image(a).resizable().renderingMode(.template).scaledToFit().foregroundStyle(tint).padding(size * 0.2)
                } else {
                    Image(a).resizable().scaledToFit().padding(size * 0.16)
                }
            } else {
                Image(systemName: b?.key == "jura" ? "scalemass" : "tray").font(.system(size: size * 0.42)).foregroundStyle(Theme.sec)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(b?.name ?? "Beslutning")
    }
}

// MARK: - Formatting
func markdown(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

func daNumber(_ v: Double?, decimals: Int = 0) -> String {
    guard let v else { return "-" }
    let f = NumberFormatter(); f.locale = Locale(identifier: "da_DK"); f.numberStyle = .decimal
    f.maximumFractionDigits = decimals; f.minimumFractionDigits = decimals
    return f.string(from: NSNumber(value: v)) ?? "\(v)"
}

/// No dashes in visible text (Kaneo's writing rule): server text is shown with " · " instead.
func clean(_ s: String) -> String {
    s.replacingOccurrences(of: " — ", with: " · ").replacingOccurrences(of: " – ", with: " · ")
        .replacingOccurrences(of: "—", with: ", ").replacingOccurrences(of: "–", with: "-")
}
