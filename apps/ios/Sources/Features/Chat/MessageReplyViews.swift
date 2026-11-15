import SwiftUI

/// A compact copy of the referenced message. The caller supplies host-backed text
/// and opens the thread; this view does not look up or store messages.
struct ReplyQuoteBubble: View {
    let text: String?
    let outgoing: Bool
    let maximumWidth: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ReplyQuoteText(text: text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .overlay {
                    MessageBubbleShape(outgoing: outgoing, showsTail: true)
                        .stroke(Color(uiColor: .separator), lineWidth: 1)
                }
                .frame(maxWidth: maximumWidth, alignment: outgoing ? .trailing : .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("native.reply.quote"))
        .accessibilityValue(accessibilityText)
        .accessibilityHint(Text("native.reply.openThread"))
        .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
    }

    private var accessibilityText: Text {
        if let text, !text.isEmpty { Text(text) }
        else { Text("native.reply.unavailable") }
    }
}

private struct ReplyQuoteText: View {
    let text: String?

    var body: some View {
        Group {
            if let text, !text.isEmpty {
                Text(text)
            } else {
                Text("native.reply.unavailable")
            }
        }
    }
}

struct ReplyCountButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ReplyCountText(count: count)
                .font(.caption)
                .foregroundStyle(MessagesStyle.accent)
                .padding(.horizontal, 5)
                .padding(.top, 4)
                .frame(minHeight: 44, alignment: .top)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("native.reply.openThread"))
    }
}

private struct ReplyCountText: View {
    let count: Int

    var body: some View {
        Group {
            if count == 1 { Text("native.reply.count.one") }
            else { Text("native.reply.count \(max(0, count))") }
        }
    }
}

/// A decorative rule beside a group of actual reply messages. Its height follows
/// the caller's reply content, including text size and attachment changes.
struct ReplyConnector: View {
    let isOutgoing: Bool

    var body: some View {
        ReplyConnectorShape()
            .stroke(Color(uiColor: .tertiaryLabel).opacity(0.45), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
            .frame(width: 24)
            .scaleEffect(x: isOutgoing ? -1 : 1, y: 1)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

private struct ReplyConnectorShape: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let x: CGFloat = 3
        let middle = rect.height * 0.53
        let radius = min(6.5, rect.height / 6)
        var path = Path()
        path.move(to: CGPoint(x: x, y: 2))
        path.addLine(to: CGPoint(x: x, y: max(2, middle - radius * 2)))
        path.addQuadCurve(
            to: CGPoint(x: x + radius, y: middle - radius),
            control: CGPoint(x: x, y: middle - radius)
        )
        path.addEllipse(in: CGRect(x: x + radius * 0.4, y: middle - radius, width: radius * 2, height: radius * 2))
        path.move(to: CGPoint(x: x + radius, y: middle + radius))
        path.addQuadCurve(
            to: CGPoint(x: x, y: middle + radius * 2),
            control: CGPoint(x: x, y: middle + radius)
        )
        path.addLine(to: CGPoint(x: x, y: max(2, rect.height - 2)))
        return path
    }
}

/// Main-history presentation of one referenced parent and its replies. The
/// caller determines which messages belong together from host metadata.
struct ReplyThreadGroup<Content: View>: View {
    let quoteText: String?
    let quoteOutgoing: Bool
    let replyCount: Int
    let maximumWidth: CGFloat
    let openThread: () -> Void
    private let content: Content

    init(
        quoteText: String?,
        quoteOutgoing: Bool,
        replyCount: Int,
        maximumWidth: CGFloat,
        openThread: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.quoteText = quoteText
        self.quoteOutgoing = quoteOutgoing
        self.replyCount = replyCount
        self.maximumWidth = maximumWidth
        self.openThread = openThread
        self.content = content()
    }

    var body: some View {
        VStack(alignment: quoteOutgoing ? .trailing : .leading, spacing: 6) {
            ReplyQuoteBubble(text: quoteText, outgoing: quoteOutgoing, maximumWidth: maximumWidth, action: openThread)
            VStack(alignment: quoteOutgoing ? .trailing : .leading, spacing: 5) {
                ReplyCountButton(count: replyCount, action: openThread)
                    .padding(quoteOutgoing ? .trailing : .leading, 24)
                content
            }
            .frame(maxWidth: .infinity, alignment: quoteOutgoing ? .trailing : .leading)
            .background(alignment: quoteOutgoing ? .trailing : .leading) {
                ReplyConnector(isOutgoing: quoteOutgoing)
                    .padding(quoteOutgoing ? .trailing : .leading, 12)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
            }
        }
    }
}

/// Focused reply presentation above a blurred, inactive conversation. The
/// caller supplies the real header, parent/replies and composer, and owns all
/// navigation, keyboard focus, draft state and asynchronous work.
struct FocusedReplyThread<Backdrop: View, Header: View, Thread: View, Composer: View>: View {
    let close: () -> Void
    let showsHeader: Bool
    private let backdrop: Backdrop
    private let header: Header
    private let thread: Thread
    private let composer: Composer

    init(
        close: @escaping () -> Void,
        showsHeader: Bool = true,
        @ViewBuilder backdrop: () -> Backdrop,
        @ViewBuilder header: () -> Header,
        @ViewBuilder thread: () -> Thread,
        @ViewBuilder composer: () -> Composer
    ) {
        self.close = close
        self.showsHeader = showsHeader
        self.backdrop = backdrop()
        self.header = header()
        self.thread = thread()
        self.composer = composer()
    }

    var body: some View {
        ZStack {
            backdrop
                .blur(radius: 20)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                if showsHeader { ReplyThreadHeader(close: close) { header } }
                ScrollView {
                    thread
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16)
                        .padding(.top, 20)
                        .padding(.bottom, 18)
                }
                .defaultScrollAnchor(.bottom)
                .defaultScrollAnchor(.bottom, for: .alignment)
                .scrollDismissesKeyboard(.interactively)
                composer
            }
        }
    }
}

private struct ReplyThreadHeader<Content: View>: View {
    let close: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) {
                GlassIconButton(symbol: "xmark", label: "native.reply.close", action: close)
                    .padding(.trailing, 16)
            }
    }
}

/// Visual progress only. The parent owns the gesture and an accessible Reply
/// action, so this decoration does not add another accessibility element.
struct ReplySwipeIndicator: View {
    let progress: CGFloat

    var body: some View {
        let amount = progress.isFinite ? min(max(progress, 0), 1) : 0
        Image(systemName: "arrowshape.turn.up.left.fill")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 44, height: 44)
            .scaleEffect(0.75 + amount * 0.25)
            .opacity(amount)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}
