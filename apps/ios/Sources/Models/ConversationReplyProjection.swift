import Foundation

/// A presentation index. Exact host reply targets stay on the original messages;
/// canonical roots below are used only to display related messages together.
struct ConversationReplyProjection {
    private(set) var messagesByID: [String: ChatMessage]
    let rootsByID: [String: String]
    private(set) var timeline: [ReplyTimelineItem]
    private(set) var repliesByRootID: [String: [ChatMessage]]
    let rowIndices: [String: Int]
    private let timelinePositions: [String: Position]
    private let replyIndices: [String: Int]

    private struct Position {
        let group: Int
        let message: Int
    }

    static func make(messages: [ChatMessage], page: HostPage?) -> Self {
        var lookup: [String: ChatMessage] = [:]
        for reference in page?.references?.values ?? Dictionary<String, HostMessage>().values where reference.isVisible {
            lookup[reference.id] = ChatMessage(
                id: reference.id, content: .text(reference.text), isOutgoing: reference.author == "user",
                attachments: reference.attachments, replyToMessageId: reference.replyToMessageId, turnId: reference.turnId
            )
        }
        for message in messages { lookup[message.id] = message }

        let roots = ReplyGraph(messages: lookup, page: page).canonicalRoots()
        var timeline: [ReplyTimelineItem] = []
        var replies: [String: [ChatMessage]] = [:]
        var rowIndices: [String: Int] = [:]
        var timelinePositions: [String: Position] = [:]
        var replyIndices: [String: Int] = [:]
        for (index, message) in messages.enumerated() {
            rowIndices[message.id] = index
            let root = roots[message.id]
            if let root, timeline.last?.rootID == root {
                let group = timeline.count - 1
                timelinePositions[message.id] = Position(group: group, message: timeline[group].messages.count)
                timeline[group].messages.append(message)
            } else {
                timelinePositions[message.id] = Position(group: timeline.count, message: 0)
                timeline.append(ReplyTimelineItem(id: message.id, rootID: root, messages: [message]))
            }
            if let root {
                replyIndices[message.id] = replies[root]?.count ?? 0
                replies[root, default: []].append(message)
            }
        }
        return Self(messagesByID: lookup, rootsByID: roots, timeline: timeline, repliesByRootID: replies,
                    rowIndices: rowIndices, timelinePositions: timelinePositions, replyIndices: replyIndices)
    }

    /// Text-only streaming does not alter graph edges, order or immutable row metadata.
    /// The owner must rebuild when a message first becomes visible or metadata changes.
    mutating func updateText(_ text: String, for messageID: String) -> Bool {
        guard var message = messagesByID[messageID], case .text = message.content,
              let timelinePosition = timelinePositions[messageID] else { return false }
        message.content = .text(text)
        messagesByID[messageID] = message
        timeline[timelinePosition.group].messages[timelinePosition.message] = message
        if let root = rootsByID[messageID], let index = replyIndices[messageID] {
            repliesByRootID[root]?[index] = message
        }
        return true
    }
}

/// Dependency edges include every input of an eligible turn. Resolving a turn
/// through all of its inputs avoids order-dependent guesses about mixed roots.
private struct ReplyGraph {
    private enum Kind {
        case message(String)
        case turn
    }

    private struct Node {
        let kind: Kind
        var dependencies: [Int] = []
        var explicit = false
    }

    private struct Turn {
        let completeStart: Bool
        var inputs: [String] = []
        var outputs: [String] = []
        var hasAgentInput = false
    }

    private var nodes: [Node] = []
    private var messageNodes: [String: Int] = [:]

    init(messages: [String: ChatMessage], page: HostPage?) {
        for id in messages.keys { _ = addMessage(id) }
        for message in messages.values {
            guard let target = message.replyToMessageId, let index = messageNodes[message.id] else { continue }
            let parent = addMessage(target)
            nodes[index].dependencies = [parent]
            nodes[index].explicit = true
        }
        guard let page else { return }
        var turns: [String: Turn] = [:]
        for (index, message) in page.messages.enumerated() {
            guard let turn = message.turnId else { continue }
            if turns[turn] == nil {
                let preceding = index > 0 ? page.messages[index - 1].turnId : nil
                turns[turn] = Turn(completeStart: page.pageInfo?.hasOlder == false || (preceding != nil && preceding != turn))
            }
            guard message.isVisible else { continue }
            switch message.author {
            case "user": turns[turn]?.inputs.append(message.id)
            case "assistant": turns[turn]?.outputs.append(message.id)
            case "agent": turns[turn]?.hasAgentInput = true
            default: break
            }
        }
        for turn in turns.values {
            guard turn.completeStart, !turn.hasAgentInput, !turn.inputs.isEmpty,
                  turn.inputs.allSatisfy({ messages[$0]?.replyToMessageId != nil }),
                  turn.inputs.allSatisfy({ messageNodes[$0] != nil }) else { continue }
            let outputs = turn.outputs.compactMap { id -> Int? in
                guard let index = messageNodes[id], messages[id] != nil, !nodes[index].explicit else { return nil }
                return index
            }
            guard !outputs.isEmpty else { continue }
            let turnIndex = nodes.count
            nodes.append(Node(kind: .turn, dependencies: turn.inputs.compactMap { messageNodes[$0] }))
            for output in outputs { nodes[output].dependencies = [turnIndex] }
        }
    }

    private mutating func addMessage(_ id: String) -> Int {
        if let index = messageNodes[id] { return index }
        let index = nodes.count
        messageNodes[id] = index
        nodes.append(Node(kind: .message(id)))
        return index
    }

    func canonicalRoots() -> [String: String] {
        let cycles = cycleMembers()
        var resolved = Array(repeating: false, count: nodes.count)
        var roots = Array<String?>(repeating: nil, count: nodes.count)
        // An inferred cycle discards that inference. Explicit-only cycles have
        // no valid root. SCC discovery and resolution both use bounded stacks.
        for index in cycles.disabledTurns.union(cycles.explicitCycles) { resolved[index] = true }
        var visiting = Array(repeating: false, count: nodes.count)
        for start in nodes.indices where !resolved[start] {
            var stack: [Frame] = [Frame(node: start)]
            visiting[start] = true
            while let frame = stack.last {
                let dependencies = nodes[frame.node].dependencies
                if frame.next < dependencies.count {
                    let dependency = dependencies[frame.next]
                    stack[stack.count - 1].next += 1
                    if !resolved[dependency] && !visiting[dependency] {
                        visiting[dependency] = true
                        stack.append(Frame(node: dependency))
                    }
                    continue
                }
                switch nodes[frame.node].kind {
                case .message(let id):
                    if let dependency = dependencies.first {
                        roots[frame.node] = nodes[frame.node].explicit ? roots[dependency] : roots[dependency] ?? id
                    } else { roots[frame.node] = id }
                case .turn:
                    if let first = dependencies.first, let root = roots[first],
                       dependencies.allSatisfy({ roots[$0] == root }) { roots[frame.node] = root }
                }
                resolved[frame.node] = true
                visiting[frame.node] = false
                stack.removeLast()
            }
        }
        var result: [String: String] = [:]
        for (id, index) in messageNodes {
            if let root = roots[index], root != id { result[id] = root }
        }
        return result
    }

    private struct Frame {
        let node: Int
        var next = 0
    }

    /// Iterative Kosaraju traversal: O(nodes + edges), with no call-stack growth
    /// for deep reply chains. Only cycle components need special handling.
    private func cycleMembers() -> (disabledTurns: Set<Int>, explicitCycles: Set<Int>) {
        var visited = Array(repeating: false, count: nodes.count)
        var finish: [Int] = []
        for start in nodes.indices where !visited[start] {
            visited[start] = true
            var stack: [Frame] = [Frame(node: start)]
            while let frame = stack.last {
                let dependencies = nodes[frame.node].dependencies
                if frame.next < dependencies.count {
                    let dependency = dependencies[frame.next]
                    stack[stack.count - 1].next += 1
                    if !visited[dependency] {
                        visited[dependency] = true
                        stack.append(Frame(node: dependency))
                    }
                } else {
                    finish.append(frame.node)
                    stack.removeLast()
                }
            }
        }
        var reverse = Array(repeating: [Int](), count: nodes.count)
        for index in nodes.indices {
            for dependency in nodes[index].dependencies { reverse[dependency].append(index) }
        }
        visited = Array(repeating: false, count: nodes.count)
        var disabledTurns: Set<Int> = []
        var explicitCycles: Set<Int> = []
        for start in finish.reversed() where !visited[start] {
            visited[start] = true
            var component: [Int] = []
            var stack = [start]
            while let index = stack.popLast() {
                component.append(index)
                for predecessor in reverse[index] where !visited[predecessor] {
                    visited[predecessor] = true
                    stack.append(predecessor)
                }
            }
            guard component.count > 1 || nodes[start].dependencies.contains(start) else { continue }
            let turnMembers = component.filter { if case .turn = nodes[$0].kind { true } else { false } }
            if turnMembers.isEmpty { explicitCycles.formUnion(component) }
            else { disabledTurns.formUnion(turnMembers) }
        }
        return (disabledTurns, explicitCycles)
    }
}
