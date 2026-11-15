import Foundation

struct Conversation: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    let avatar: String
    var preview: String
    var dateLabel: String
    var messages: [ChatMessage]
    var isPinned = false
    var isUnread = false
    var isMuted = false
    var sendsReadReceipts = true
    var translatesAutomatically = false
    var isBlocked = false
    var isVisible = true
    var background: ChatBackground = .plain
    var phone: String?
    var isVerified = false
}

enum ChatBackground: String, Codable, CaseIterable, Identifiable {
    case plain, sky, rose, sage
    var id: Self { self }
}

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: String
    var content: MessageContent
    var isOutgoing = false
    var timestamp: String?
    var receipt: String?
    var reaction: Reaction?
    var showsTail = true
    var deliveryState: MessageDeliveryState?
    var isStreaming: Bool?
    var attachments: [HostAttachment]? = nil
    var liveReactions: [HostReaction]? = nil
    var userReaction: String? = nil
    var replyToMessageId: String? = nil
    var turnId: String? = nil
}

enum MessageDeliveryState: String, Codable {
    case queued, sending, sent, failed, unconfirmed
}

enum MessageContent: Codable, Equatable {
    case text(String)
    case emoji(String)
    case link(title: String, domain: String)
    case attachment(name: String, detail: String)
}

enum Reaction: String, Codable, CaseIterable, Identifiable {
    case heart, like, dislike, laugh, emphasis, question, redHeart, loveFace
    var id: Self { self }

    var emoji: String {
        switch self {
        case .heart: "🩷"
        case .like: "👍"
        case .dislike: "👎"
        case .laugh: "😂"
        case .emphasis: "‼️"
        case .question: "❓"
        case .redHeart: "❤️"
        case .loveFace: "😍"
        }
    }

    var pickerAsset: String? {
        switch self {
        case .heart: "tapback-heart"
        case .laugh: "tapback-laugh"
        case .question: "tapback-question"
        default: nil
        }
    }
}
