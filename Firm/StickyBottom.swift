import SwiftUI

/// A conversation should follow the newest message only while you are already down there.
/// Before this, every arriving reply yanked the view back to the bottom — so reading what
/// someone said further up was impossible while the room was still answering, and the
/// screen felt frozen because it kept snapping away from wherever you scrolled.
struct FollowsBottom: ViewModifier {
    @Binding var atBottom: Bool
    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: Bool.self) { geo in
            // within a bubble's height of the end counts as "at the bottom"
            geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 90
        } action: { _, isNear in
            if isNear != atBottom { atBottom = isNear }
        }
    }
}

extension View {
    func followsBottom(_ atBottom: Binding<Bool>) -> some View {
        modifier(FollowsBottom(atBottom: atBottom))
    }
}

/// Shown only when you have scrolled away and something new has arrived.
struct JumpToLatest: View {
    let unread: Int
    let tap: () -> Void
    var body: some View {
        Button(action: tap) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                Text(unread > 0 ? "\(unread) new" : "Latest")
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
