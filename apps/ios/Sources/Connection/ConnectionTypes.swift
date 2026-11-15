import Foundation
import CryptoKit

enum WireValue: Codable, Sendable, Equatable {
    case object([String: WireValue]), array([WireValue]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode(Double.self) { self = .number(item) }
        else if let item = try? value.decode([String: WireValue].self) { self = .object(item) }
        else { self = .array(try value.decode([WireValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .bool(let item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }

    subscript(_ key: String) -> WireValue? { if case .object(let values) = self { values[key] } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var integer: Int? { if case .number(let value) = self, value.isFinite, value >= 0, value < Double(Int.max) { Int(value) } else { nil } }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: JSONEncoder().encode(self)) }
}

struct HostCredential: Codable, Sendable {
    var apiUrl: String
    var sessionToken: String
    var userName: String
    var email: String
    var host: HostBinding?
    var hostKeys: [String: String]
    var selectedHostID: String?
    var membershipId: String?

    var workspaceID: String? {
        guard let host = selectedHostID, let member = membershipId else { return nil }
        return workspaceID(hostID: host, membershipID: member)
    }

    func workspaceID(hostID host: String, membershipID member: String) -> String {
        let identity = [apiUrl, email.lowercased(), host, member].joined(separator: "\n")
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct HostBinding: Codable, Sendable {
    let hostId: String
    let fingerprint: String
}

struct ConnectedHost: Decodable, Identifiable, Sendable {
    let hostId: String
    let name: String
    let membershipId: String
    var id: String { hostId }
}

struct HostAgent: Codable, Sendable {
    let id: String
    let name: String
    let title: String?
    var preview: String? = nil
    var updatedAt: String? = nil
}

struct HostPage: Codable, Sendable {
    struct PageInfo: Codable, Sendable {
        let hasOlder: Bool
        let olderCursor: String?
    }
    let agentId: String
    let threadId: String?
    let activeTurnId: String?
    var revision: Int
    var messages: [HostMessage]
    var pageInfo: PageInfo? = nil
    var recentPageInfo: PageInfo? = nil
    var references: [String: HostMessage]? = nil
}

struct HostMessage: Codable, Sendable {
    let id: String
    let author: String
    var text: String
    let createdAt: String
    let status: String
    let itemType: String?
    var attachments: [HostAttachment]? = nil
    var reaction: String? = nil
    var reactions: [HostReaction]? = nil
    var replyToMessageId: String? = nil
    var turnId: String? = nil
    var source: String? = nil

    var isVisible: Bool {
        canDisplayText && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachments?.isEmpty == false)
    }

    var canDisplayText: Bool {
        (author == "user" || author == "assistant" || author == "agent") &&
        !(author == "user" && (itemType == "routine" || source == "routine")) &&
        !["commentary", "reasoning", "tool_call", "question_prompt", "plan", "subagents", "routine_quiet_answer", "agent_welcome"].contains(itemType ?? "") &&
        !id.hasSuffix(":reasoning")
    }
}

struct HostReaction: Codable, Equatable, Identifiable, Sendable {
    struct Actor: Codable, Equatable, Sendable {
        let kind: String
        var agentId: String? = nil
    }
    let emoji: String
    let actor: Actor
    var id: String { actor.kind + ":" + (actor.agentId ?? "") }
}

struct HostAttachment: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let mimeType: String
    let size: Int
    let kind: String
    let previewKind: String?
}

enum ConnectionPhase: Equatable {
    case preview, signingIn, connecting, online, offline
}

enum ConnectionProblem: String, Error, Decodable {
    case network, invalidLink, auth, invalidCode, incompatible, hostMissing, unconfirmed, sendFailed, keychain, protocolError, storage

    var text: LocalizedStringResource { "native.error.generic" }
}
