import SwiftUI
import Foundation

struct MessageBubble: View {
    let message: ChatMessage
    let maximumWidth: CGFloat
    var openAttachment: ((String, String) -> Void)?
    var selectableText = true

    var body: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 5) {
            content
                .overlay(alignment: .topTrailing) {
                    if let reactions = message.liveReactions, !reactions.isEmpty {
                        LiveReactionSummary(reactions: reactions)
                            .offset(x: -2, y: -28)
                    } else if let reaction = message.reaction {
                        ReactionBadge(reaction: reaction)
                            .offset(x: -2, y: -28)
                            .accessibilityLabel(Text("native.reaction.label \(reaction.emoji)"))
                    }
                }
            if let receipt = message.receipt {
                Text(receipt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 8)
            } else if let state = message.deliveryState {
                Text(state.title)
                    .font(.caption)
                    .foregroundStyle(state == .failed ? .red : .secondary)
                    .padding(.trailing, 8)
            }
        }
        .padding(.top, message.reaction == nil && (message.liveReactions?.isEmpty ?? true) ? 0 : 26)
        .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch message.content {
        case .text(let text):
            BubbleText(text: text, outgoing: message.isOutgoing, selectable: selectableText)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleColor, in: MessageBubbleShape(outgoing: message.isOutgoing, showsTail: message.showsTail))
                .frame(maxWidth: maximumWidth, alignment: message.isOutgoing ? .trailing : .leading)
        case .emoji(let emoji):
            Text(emoji).font(.system(size: 73)).padding(.vertical, 6).padding(.horizontal, 14)
        case .link(let title, let domain):
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    Text(domain).font(.caption).foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 0)
                if domain == "lentiamo.it" {
                    Image("lentiamo").resizable().scaledToFit().frame(width: 30, height: 30).clipShape(.rect(cornerRadius: 4))
                } else {
                    Image(systemName: "link.circle.fill").font(.system(size: 30)).foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: maximumWidth * 0.89)
            .background(Color(red: 0.27, green: 0.63, blue: 0.78), in: MessageBubbleShape(outgoing: message.isOutgoing, showsTail: message.showsTail))
        case .attachment(let name, let detail):
            Button {
                openAttachment?(name, detail)
            } label: {
                HStack(spacing: 15) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.13), radius: 2, y: 1)
                        .overlay { Image(systemName: "questionmark").foregroundStyle(.gray).font(.title3) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                        Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "square.and.arrow.down")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .background(.primary.opacity(0.07), in: .circle)
                }
                .padding(16)
                .frame(maxWidth: maximumWidth)
                .background(MessagesStyle.incoming, in: .rect(cornerRadius: 23))
            }
            .buttonStyle(.plain)
        }
    }

    private var bubbleColor: Color { message.isOutgoing ? MessagesStyle.outgoing : MessagesStyle.incoming }
}

extension MessageDeliveryState {
    var title: LocalizedStringResource {
        switch self {
        case .queued: "native.connection.queued"
        case .sending: "native.connection.sending"
        case .sent: "native.connection.sent"
        case .failed: "native.connection.notSent"
        case .unconfirmed: "native.connection.unconfirmed"
        }
    }
}

struct MessageBubbleShape: Shape {
    var outgoing: Bool
    var showsTail: Bool

    nonisolated func path(in rect: CGRect) -> Path {
        let radius = min(23, rect.height / 2)
        guard showsTail else { return Path(roundedRect: rect, cornerRadius: radius) }
        var path = Path()
        path.move(to: CGPoint(x: radius, y: 0))
        path.addLine(to: CGPoint(x: rect.width - radius, y: 0))
        path.addQuadCurve(to: CGPoint(x: rect.width, y: radius), control: CGPoint(x: rect.width, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height - radius))
        path.addCurve(to: CGPoint(x: rect.width + 5, y: rect.height + 5), control1: CGPoint(x: rect.width, y: rect.height - 5), control2: CGPoint(x: rect.width - 1, y: rect.height + 1))
        path.addCurve(to: CGPoint(x: rect.width - 15, y: rect.height - 3), control1: CGPoint(x: rect.width + 8, y: rect.height + 10), control2: CGPoint(x: rect.width - 7, y: rect.height + 3))
        path.addQuadCurve(to: CGPoint(x: rect.width - radius, y: rect.height), control: CGPoint(x: rect.width - 18, y: rect.height))
        path.addLine(to: CGPoint(x: radius, y: rect.height))
        path.addQuadCurve(to: CGPoint(x: 0, y: rect.height - radius), control: CGPoint(x: 0, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: 0), control: .zero)
        path.closeSubpath()
        if outgoing {
            return path
        } else {
            return path.applying(CGAffineTransform(translationX: rect.width, y: 0).scaledBy(x: -1, y: 1))
        }
    }
}

struct ReactionBadge: View {
    let reaction: Reaction

    var body: some View {
        Group {
            if reaction == .like {
                Image("reaction-like").resizable().scaledToFill()
            } else {
                Text(reaction.emoji).font(.system(size: 22))
            }
        }
            .frame(width: 35, height: 35)
            .clipShape(.circle)
            .background(MessagesStyle.accent, in: .circle)
            .overlay { Circle().stroke(MessagesStyle.surface, lineWidth: 1) }
            .overlay(alignment: .bottomTrailing) {
                Circle().fill(MessagesStyle.accent).frame(width: 9, height: 9).offset(x: -1, y: 2)
                    .overlay(alignment: .bottomTrailing) {
                        Circle().fill(MessagesStyle.accent).frame(width: 4, height: 4).offset(x: 4, y: 7)
                    }
            }
    }
}

/// SwiftUI owns text layout and accessibility positions as history scrolls.
private struct BubbleText: View {
    let text: String
    let outgoing: Bool
    let selectable: Bool
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    var body: some View {
        Group {
            if selectable { Text(linkedText).textSelection(.enabled) }
            else { Text(linkedText).textSelection(.disabled) }
        }
            .font(.body)
            .foregroundStyle(outgoing ? .white : .primary)
            .tint(outgoing ? .white : MessagesStyle.accent)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
            })
    }

    private var linkedText: AttributedString {
        let value = NSMutableAttributedString(string: text)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in Self.detector?.matches(in: text, range: range) ?? [] {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            value.addAttribute(.link, value: url, range: match.range)
        }
        return AttributedString(value)
    }
}

struct ConversationPreview: View {
    let messages: [ChatMessage]
    let viewportSize: CGSize

    private var previewWidth: CGFloat { max(1, min(viewportSize.width - 32, 420)) }
    private var previewHeight: CGFloat { max(1, min(viewportSize.height * 0.65, 520)) }

    var body: some View {
        ScrollView {
            VStack(spacing: 7) {
                Text("OpenBot").font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
                ForEach(messages.suffix(5)) { message in
                    VStack(spacing: 7) {
                        if let timestamp = message.timestamp {
                            Text(timestamp).font(.caption).foregroundStyle(.secondary).padding(.vertical, 5)
                        }
                        MessagePreviewPayload(message: message, maximumWidth: previewWidth * 0.70)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .scrollIndicators(.hidden)
        .scrollDisabled(true)
        .frame(width: previewWidth, height: previewHeight)
        .background(MessagesStyle.surface)
    }
}
