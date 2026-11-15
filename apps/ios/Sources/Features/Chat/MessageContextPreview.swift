import SwiftUI

/// A long bubble must not determine the system menu's preview aspect ratio.
struct MessageContextPreview: View {
    let message: ChatMessage
    let viewportSize: CGSize

    private var width: CGFloat { max(1, min(viewportSize.width - 32, 420)) }
    private var height: CGFloat { max(1, min(viewportSize.height * 0.55, 420)) }

    var body: some View {
        ViewThatFits(in: .vertical) {
            payload
            ScrollView { payload }
                .scrollDisabled(true)
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.bottom)
                .defaultScrollAnchor(.bottom, for: .alignment)
                .frame(height: height)
        }
        .frame(width: width)
        .frame(maxHeight: height)
        .background(MessagesStyle.surface)
        .allowsHitTesting(false)
    }

    private var payload: some View {
        MessagePreviewPayload(message: message, maximumWidth: width - 32)
            .padding(16)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The menu uses the same text and file metadata as the row, without opening files.
struct MessagePreviewPayload: View {
    let message: ChatMessage
    let maximumWidth: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            if hasBody { MessageBubble(message: message, maximumWidth: maximumWidth, selectableText: false) }
            ForEach(message.attachments ?? []) { attachment in
                LiveAttachmentButton(attachment: attachment, downloading: false, open: {})
                    .frame(maxWidth: maximumWidth)
                    .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
            }
        }
        .allowsHitTesting(false)
    }

    private var hasBody: Bool {
        if case .text(let text) = message.content { return !text.isEmpty }
        return true
    }
}
