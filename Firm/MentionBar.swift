import SwiftUI

/// Typing `@` used to open a row that slid sideways, so whoever did not fit was simply
/// invisible. A mention list is a list: everyone is in one column, and you scroll down
/// for the rest the way you already do everywhere else.
struct MentionBar: View {
    let ids: [String]
    let store: Store
    let pick: (String) -> Void

    private var rowHeight: CGFloat { 44 }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(ids.enumerated()), id: \.offset) { _, id in
                        Button {
                            pick(id); UISelectionFeedbackGenerator().selectionChanged()
                        } label: {
                            HStack(spacing: 10) {
                                if let a = store.agents.first(where: { $0.id == id }) {
                                    Avatar(agent: a, size: 26)
                                } else {
                                    Circle().fill(Color.agentHue(id)).frame(width: 26, height: 26)
                                }
                                Text(id.capitalized).font(.system(size: 15, weight: .medium))
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .frame(height: rowHeight)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            // Four rows is enough to choose from without eating the whole conversation.
            .frame(height: min(CGFloat(ids.count), 4) * rowHeight)
        }
        .background(.bar)
    }
}
