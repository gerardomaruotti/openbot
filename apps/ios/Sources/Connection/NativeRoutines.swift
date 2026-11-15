import Foundation
import Observation

struct NativeRoutine: Identifiable, Equatable {
    let wire: WireValue
    let id: String
    let name: String
    let instruction: String
    let active: Bool
    let timezone: String
    let schedule: WireValue?
    let nextRunAt: String?
    let updatedAt: String
    let limitPolicy: String?
    let missedPolicy: String?
    let runIn: String?

    init?(_ value: WireValue) {
        guard let id = value["id"]?.string, let name = value["name"]?.string,
              let instruction = value["instruction"]?.string, let active = value["active"]?.bool,
              let timezone = value["timezone"]?.string, let updated = value["updatedAt"]?.string else { return nil }
        wire = value; self.id = id; self.name = name; self.instruction = instruction
        self.active = active; self.timezone = timezone; updatedAt = updated
        schedule = value["trigger"]?["schedule"]
        nextRunAt = value["trigger"]?["nextRunAt"]?.string
        limitPolicy = value["limitPolicy"]?.string; missedPolicy = value["missedPolicy"]?.string
        runIn = value["runIn"]?.string
    }
}

struct NativeRoutineRun: Identifiable, Equatable {
    let id: String
    let routineID: String
    let status: String
    let kind: String
    let scheduledFor: String
    let updatedAt: String
    let error: String?
    let missedCount: Int?

    init?(_ value: WireValue) {
        guard let id = value["id"]?.string, let routine = value["routineId"]?.string,
              let status = value["status"]?.string, let kind = value["kind"]?.string,
              let scheduled = value["scheduledFor"]?.string, let updated = value["updatedAt"]?.string else { return nil }
        self.id = id; routineID = routine; self.status = status; self.kind = kind
        scheduledFor = scheduled; updatedAt = updated; error = value["error"]?.string
        missedCount = value["missed"]?["count"]?.integer
    }

    var title: LocalizedStringResource {
        switch status {
        case "queued": "native.routine.status.queued"
        case "running": "native.routine.status.running"
        case "needs-attention": "native.routine.status.attention"
        case "succeeded": "native.routine.status.succeeded"
        case "failed": "native.routine.status.failed"
        case "interrupted": "native.routine.status.interrupted"
        case "cancelled": "native.routine.status.cancelled"
        default: "native.routine.status.unknown"
        }
    }
}

/// Host records remain authoritative. Mutations carry only fields that the person changed.
@Observable
@MainActor
final class NativeRoutines {
    var contextID: Int { generation }

    func retainVisibleAgents(_ ids: Set<String>) {
        if let agentID, !ids.contains(agentID) { clear() }
    }
    private(set) var routines: [NativeRoutine] = []
    private(set) var runs: [String: [NativeRoutineRun]] = [:] {
        didSet {
            visibleRuns = runs.mapValues { history in
                history.filter { ["queued", "running", "succeeded"].contains($0.status) }
            }
        }
    }
    private(set) var visibleRuns: [String: [NativeRoutineRun]] = [:]
    private(set) var isBusy = false
    private(set) var loaded = false
    private(set) var supportsOnce = false
    private(set) var supportsRunPlaces = false
    private(set) var supportsRecovery = false
    private(set) var canManage = false
    private(set) var problem: LocalizedStringResource?
    private(set) var needsReview = false
    private var scope: String?
    private var hostID: String?
    private var agentID: String?
    private var generation = 0
    private var refreshPending = false
    private var unconfirmedRunIDs: Set<String> = []

    func clear() {
        generation += 1
        routines = []; runs = [:]; isBusy = false; loaded = false
        supportsOnce = false; supportsRunPlaces = false; supportsRecovery = false
        canManage = false
        problem = nil; needsReview = false
        scope = nil; hostID = nil; agentID = nil; refreshPending = false; unconfirmedRunIDs = []
    }

    func routine(_ id: String) -> NativeRoutine? { routines.first { $0.id == id } }

    func load(connection: AgentConnection, agentID: String, acknowledgeReview: Bool = false) async {
        if scope != connection.workspaceID || hostID != connection.hostID || self.agentID != agentID {
            clear(); scope = connection.workspaceID; hostID = connection.hostID; self.agentID = agentID
        }
        guard !isBusy else { refreshPending = true; return }
        guard let hostID, connection.canSend, scope != nil else { return }
        let epoch = generation
        isBusy = true
        if !needsReview { problem = nil }
        defer { finish(epoch: epoch, connection: connection) }
        do {
            let reply = try await connection.transport.execute(["type": .string("routinesList"), "hostId": .string(hostID), "agentId": .string(agentID)])
            guard epoch == generation, scope == connection.workspaceID, case .array(let values) = reply["routines"] else { return }
            let incoming = values.compactMap(NativeRoutine.init)
            guard incoming.count == values.count else { throw ConnectionProblem.protocolError }
            routines = incoming
            supportsOnce = reply["once"]?.bool == true
            supportsRunPlaces = reply["runPlaces"]?.bool == true
            supportsRecovery = reply["recovery"]?.bool == true
            canManage = reply["canManage"]?.bool == true
            loaded = true
            let retained = Set(incoming.map(\.id)); runs = runs.filter { retained.contains($0.key) }
            // A lost manual receipt can leave no history entry at all. Its routine ID remains
            // a required read even when it is absent from the history dictionary.
            let requiredHistories = Set(runs.keys).union(unconfirmedRunIDs)
            for id in requiredHistories.sorted() {
                guard try await readRuns(id, connection: connection, epoch: epoch) else { return }
            }
            guard epoch == generation, canUse(connection) else { return }
            if acknowledgeReview {
                unconfirmedRunIDs.subtract(requiredHistories)
                needsReview = false; problem = nil
            }
        } catch { /* Background reads keep the last available routines. */ }
    }

    func receive(_ event: WireValue, connection: AgentConnection) {
        guard event["type"]?.string == "routines-changed", event["agentId"]?.string == agentID,
              scope == connection.workspaceID, hostID == connection.hostID, let agentID else { return }
        if isBusy { refreshPending = true }
        else { Task { await load(connection: connection, agentID: agentID) } }
    }

    func loadRuns(_ routineID: String, connection: AgentConnection) async {
        guard !isBusy, canUse(connection), routine(routineID) != nil else { return }
        let epoch = generation
        isBusy = true
        if !needsReview { problem = nil }
        defer { finish(epoch: epoch, connection: connection) }
        do { _ = try await readRuns(routineID, connection: connection, epoch: epoch) }
        catch { /* Background history failures stay out of the conversation. */ }
    }

    @discardableResult
    func save(_ draft: RoutineEditorDraft, connection: AgentConnection) async -> Bool {
        guard !isBusy, !needsReview, canManage, canUse(connection),
              let hostID, let agentID else { return false }
        if let validation = draft.validation { problem = validation; return false }
        var command: [String: WireValue] = ["hostId": .string(hostID), "agentId": .string(agentID)]
        if let original = draft.original {
            guard routine(original.id)?.updatedAt == original.updatedAt else {
                problem = "native.error.generic"; needsReview = true; return false
            }
            let changes = draft.changes
            if changes.isEmpty { return true }
            command["type"] = .string("routineUpdate"); command["routineId"] = .string(original.id)
            command["expectedUpdatedAt"] = .string(original.updatedAt); command["changes"] = .object(changes)
        } else {
            command["type"] = .string("routineCreate"); command["input"] = .object(draft.creation)
        }
        let epoch = generation
        isBusy = true; problem = nil
        defer { finish(epoch: epoch, connection: connection) }
        do {
            let result = try await connection.transport.execute(command)
            guard epoch == generation, scope == connection.workspaceID, let value = NativeRoutine(result) else { throw ConnectionProblem.protocolError }
            routines.removeAll { $0.id == value.id }; routines.append(value)
            return true
        } catch {
            if epoch == generation {
                problem = "native.error.generic"
                needsReview = true
                // A create or a secondary option write can already be committed. Read it back
                // for review without acknowledging the uncertain result or repeating the write.
                refreshPending = true
            }
            return false
        }
    }

    @discardableResult
    func setActive(_ routine: NativeRoutine, active: Bool, connection: AgentConnection) async -> Bool {
        var draft = RoutineEditorDraft(routine: routine)
        draft.active = active
        return await save(draft, connection: connection)
    }

    @discardableResult
    func delete(_ routine: NativeRoutine, connection: AgentConnection) async -> Bool {
        guard !isBusy, !needsReview, canManage, canUse(connection), let hostID, let agentID else { return false }
        let epoch = generation
        isBusy = true; problem = nil
        defer { finish(epoch: epoch, connection: connection) }
        do {
            _ = try await connection.transport.execute(["type": .string("routineDelete"), "hostId": .string(hostID), "agentId": .string(agentID), "routineId": .string(routine.id), "expectedUpdatedAt": .string(routine.updatedAt)])
            guard epoch == generation else { return false }
            routines.removeAll { $0.id == routine.id }; runs[routine.id] = nil
            return true
        } catch {
            if epoch == generation { problem = "native.error.generic"; needsReview = true }
            return false
        }
    }

    @discardableResult
    func runNow(_ routine: NativeRoutine, connection: AgentConnection) async -> Bool {
        guard !isBusy, !needsReview, canManage, canUse(connection), !hasUnfinishedRun(routine.id), let hostID, let agentID else { return false }
        let epoch = generation
        isBusy = true; problem = nil
        defer { finish(epoch: epoch, connection: connection) }
        do {
            let reply = try await connection.transport.execute(["type": .string("routineTest"), "hostId": .string(hostID), "agentId": .string(agentID), "routineId": .string(routine.id), "expectedUpdatedAt": .string(routine.updatedAt)])
            guard epoch == generation, let run = NativeRoutineRun(reply) else { throw ConnectionProblem.protocolError }
            var history = runs[routine.id, default: []]
            history.removeAll { $0.id == run.id }; history.insert(run, at: 0); runs[routine.id] = history
            return true
        } catch {
            if epoch == generation {
                unconfirmedRunIDs.insert(routine.id)
                problem = "native.error.generic"; needsReview = true
            }
            return false
        }
    }

    private func readRuns(_ routineID: String, connection: AgentConnection, epoch: Int) async throws -> Bool {
        guard epoch == generation, canUse(connection), let hostID, let agentID else { return false }
        let reply = try await connection.transport.execute(["type": .string("routineRuns"), "hostId": .string(hostID), "agentId": .string(agentID), "routineId": .string(routineID), "limit": .number(50)])
        guard epoch == generation, canUse(connection) else { return false }
        guard case .array(let values) = reply else { throw ConnectionProblem.protocolError }
        let history = values.compactMap(NativeRoutineRun.init)
        guard history.count == values.count else { throw ConnectionProblem.protocolError }
        runs[routineID] = history
        return true
    }

    private func canUse(_ connection: AgentConnection) -> Bool {
        scope != nil && scope == connection.workspaceID && hostID == connection.hostID && connection.canSend
    }

    func hasUnfinishedRun(_ id: String) -> Bool {
        runs[id]?.contains { ["queued", "running", "needs-attention"].contains($0.status) } == true
    }

    private func finish(epoch: Int, connection: AgentConnection) {
        guard epoch == generation else { return }
        isBusy = false
        if refreshPending, let agentID {
            refreshPending = false
            Task { await load(connection: connection, agentID: agentID) }
        }
    }
}

enum RoutineScheduleKind: String, CaseIterable, Identifiable {
    case hourly, daily, weekdays, weekly, monthly, interval, advanced, custom, once
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .hourly: "native.routine.schedule.hourly"
        case .daily: "native.routine.schedule.daily"
        case .weekdays: "native.routine.schedule.weekdays"
        case .weekly: "native.routine.schedule.weekly"
        case .monthly: "native.routine.schedule.monthly"
        case .interval: "native.routine.schedule.interval"
        case .advanced: "native.routine.schedule.advanced"
        case .custom: "native.routine.schedule.custom"
        case .once: "native.routine.schedule.once"
        }
    }
}

struct RoutineScheduleDraft: Equatable {
    var kind: RoutineScheduleKind = .daily
    var time = "09:00"
    var minute = 0
    var weekday = 1
    var day = 1
    var amount = 1
    var unit = "hours"
    var anchorAt = Date.now
    private var sourceAnchor: String?
    private var initialAnchorAt: Date?
    var unparsedAnchor: String? { sourceAnchor.flatMap { RoutineClock.parse($0) == nil ? $0 : nil } }

    mutating func replaceUnparsedAnchor() {
        sourceAnchor = nil
        anchorAt = .now
        initialAnchorAt = nil
    }
    var date = RoutineClock.dateString(.now)
    var expression = ""
    var months: Set<Int> = Set(1...12)
    var dayKind = "every-day"
    var selectedDays: Set<Int> = []
    var timeKind = "at-time"
    var advancedAmount = 1
    var advancedUnit = "hours"

    init(_ value: WireValue? = nil) {
        guard let value, let rawKind = value["kind"]?.string, let kind = RoutineScheduleKind(rawValue: rawKind) else { return }
        self.kind = kind
        time = value["time"]?.string ?? "09:00"; minute = value["minute"]?.integer ?? 0
        weekday = value["weekday"]?.integer ?? 1; day = value["day"]?.integer ?? 1
        amount = value["amount"]?.integer ?? 1; unit = value["unit"]?.string ?? "hours"
        sourceAnchor = value["anchorAt"]?.string
        anchorAt = sourceAnchor.flatMap(RoutineClock.parse) ?? .now
        initialAnchorAt = anchorAt
        date = value["date"]?.string ?? date; expression = value["expression"]?.string ?? ""
        if case .array(let values) = value["months"] { months = Set(values.compactMap(\.integer)) }
        dayKind = value["days"]?["kind"]?.string ?? "every-day"
        if case .array(let values) = value["days"]?["days"] { selectedDays = Set(values.compactMap(\.integer)) }
        timeKind = value["time"]?["kind"]?.string ?? "at-time"
        if kind == .advanced { time = value["time"]?["time"]?.string ?? "09:00" }
        advancedAmount = value["time"]?["amount"]?.integer ?? 1; advancedUnit = value["time"]?["unit"]?.string ?? "hours"
    }

    var wire: WireValue {
        var result: [String: WireValue] = ["kind": .string(kind.rawValue)]
        switch kind {
        case .hourly: result["minute"] = .number(Double(minute))
        case .daily, .weekdays: result["time"] = .string(time)
        case .weekly: result["weekday"] = .number(Double(weekday)); result["time"] = .string(time)
        case .monthly: result["day"] = .number(Double(day)); result["time"] = .string(time)
        case .interval:
            result["amount"] = .number(Double(amount)); result["unit"] = .string(unit)
            let retainedAnchor = sourceAnchor.flatMap { initialAnchorAt == anchorAt ? $0 : nil }
            result["anchorAt"] = .string(retainedAnchor ?? anchorAt.ISO8601Format())
        case .advanced:
            result["months"] = .array(months.sorted().map { .number(Double($0)) })
            var days: [String: WireValue] = ["kind": .string(dayKind)]
            if dayKind != "every-day" { days["days"] = .array(selectedDays.sorted().map { .number(Double($0)) }) }
            result["days"] = .object(days)
            result["time"] = timeKind == "at-time" ? .object(["kind": .string(timeKind), "time": .string(time)]) : .object(["kind": .string(timeKind), "amount": .number(Double(advancedAmount)), "unit": .string(advancedUnit)])
        case .custom: result["expression"] = .string(expression.trimmingCharacters(in: .whitespacesAndNewlines))
        case .once: result["date"] = .string(date); result["time"] = .string(time)
        }
        return .object(result)
    }

    var validation: LocalizedStringResource? {
        if kind == .interval && (!(1...100_000).contains(amount) || unit == "minutes" && amount < 3) { return "native.routine.minimumInterval" }
        if kind == .advanced {
            if months.isEmpty || dayKind != "every-day" && selectedDays.isEmpty { return "native.routine.selectDays" }
            if dayKind == "days-of-week" && !selectedDays.isSubset(of: Set(0...6)) { return "native.routine.selectDays" }
            if dayKind == "days-of-month" && !selectedDays.isSubset(of: Set(1...31)) { return "native.routine.selectDays" }
            if timeKind == "every" && (!(1...100_000).contains(advancedAmount) || advancedUnit == "minutes" && advancedAmount < 3) { return "native.routine.minimumInterval" }
        }
        if kind == .custom && (expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || expression.count > 255) { return "native.error.generic" }
        return nil
    }
}

struct RoutineEditorDraft {
    let original: NativeRoutine?
    var name: String
    var instruction: String
    var active: Bool
    var timezone: String
    var schedule: RoutineScheduleDraft
    var scheduleChanged = false
    var limitPolicy: String
    var missedPolicy: String
    var runIn: String

    init(routine: NativeRoutine? = nil) {
        original = routine; name = routine?.name ?? ""; instruction = routine?.instruction ?? ""
        active = routine?.active ?? false; timezone = routine?.timezone ?? TimeZone.current.identifier
        schedule = RoutineScheduleDraft(routine?.schedule)
        limitPolicy = routine?.limitPolicy ?? "wait"; missedPolicy = routine?.missedPolicy ?? "skip"
        runIn = routine?.runIn ?? "chat"
    }

    var validation: LocalizedStringResource? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 80 || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || instruction.count > 100_000 { return "native.routine.required" }
        if TimeZone(identifier: timezone) == nil { return "native.error.generic" }
        if original == nil || scheduleChanged {
            if let problem = schedule.validation { return problem }
        }
        if schedule.kind == .once && (original == nil || scheduleChanged || active && original?.active == false),
           let at = RoutineClock.instant(date: schedule.date, time: schedule.time, timezone: timezone), at <= .now { return "native.routine.onceFuture" }
        return nil
    }

    var creation: [String: WireValue] {
        var values: [String: WireValue] = ["name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)), "instruction": .string(instruction), "active": .bool(active), "timezone": .string(timezone), "schedule": schedule.wire]
        if limitPolicy != "wait" { values["limitPolicy"] = .string(limitPolicy) }
        if missedPolicy != "skip" { values["missedPolicy"] = .string(missedPolicy) }
        if runIn != "chat" { values["runIn"] = .string(runIn) }
        return values
    }

    var changes: [String: WireValue] {
        guard let original else { return [:] }
        var values: [String: WireValue] = [:]
        if name != original.name { values["name"] = .string(name.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if instruction != original.instruction { values["instruction"] = .string(instruction) }
        if active != original.active { values["active"] = .bool(active) }
        if scheduleChanged { values["schedule"] = schedule.wire }
        if limitPolicy != (original.limitPolicy ?? "wait") { values["limitPolicy"] = .string(limitPolicy) }
        if missedPolicy != (original.missedPolicy ?? "skip") { values["missedPolicy"] = .string(missedPolicy) }
        if runIn != (original.runIn ?? "chat") { values["runIn"] = .string(runIn) }
        return values
    }
}

enum RoutineClock {
    static let utc = TimeZone(secondsFromGMT: 0) ?? .current
    static func parse(_ value: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value)) ?? (try? Date.ISO8601FormatStyle().parse(value))
    }
    static func dateString(_ value: Date) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = utc
        let parts = calendar.dateComponents([.year, .month, .day], from: value)
        return String(format: "%04d-%02d-%02d", parts.year ?? 2000, parts.month ?? 1, parts.day ?? 1)
    }
    static func instant(date: String, time: String, timezone: String) -> Date? {
        let dateParts = date.split(separator: "-").compactMap { Int($0) }, timeParts = time.split(separator: ":").compactMap { Int($0) }
        guard dateParts.count == 3, timeParts.count == 2, let zone = TimeZone(identifier: timezone) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: dateParts[0], month: dateParts[1], day: dateParts[2], hour: timeParts[0], minute: timeParts[1]))
    }
}
