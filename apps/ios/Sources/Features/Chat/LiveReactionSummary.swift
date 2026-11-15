import SwiftUI

struct LiveReactionSummary: View {
    let reactions: [HostReaction]
    @State private var showsAll = false

    var body: some View {
        Button { showsAll = true } label: {
            HStack(spacing: -4) {
                ForEach(reactions.prefix(2)) { reaction in
                    Text(reaction.emoji)
                        .font(.system(size: 20))
                        .frame(width: 34, height: 34)
                        .background(reaction.actor.kind == "user" ? MessagesStyle.accent : MessagesStyle.incoming, in: .circle)
                        .overlay(Circle().stroke(.background, lineWidth: 1))
                }
                if reactions.count > 2 {
                    Text(reactions.count - 2, format: .number)
                        .font(.caption.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .background(.regularMaterial, in: .circle)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("native.reaction.summary \(reactions.count)"))
        .sheet(isPresented: $showsAll) {
            NavigationStack {
                List(reactions) { reaction in
                    HStack {
                        Text(reaction.emoji).font(.title)
                        Text(reaction.actor.kind == "user" ? "native.reaction.you" : "native.connection.agent")
                    }
                }
                .navigationTitle("native.reaction.title")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("native.action.done") { showsAll = false } } }
            }
            .presentationDetents([.medium, .large])
        }
    }
}
