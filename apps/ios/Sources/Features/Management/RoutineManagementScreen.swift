import SwiftUI

struct RoutineManagementScreen: View {
    @Environment(AppHaptics.self) private var haptics
    @State private var isVisible = false
    let connection: AgentConnection
    let model: NativeRoutines
    let agentID: String
    let agentName: String
    @State private var showsCreate = false
    @State private var showsActionError = false
    @State private var initialLoadFailed = false

    var body: some View {
        List {
            if showsActionError || initialLoadFailed && !model.loaded {
                Text("native.error.generic").foregroundStyle(.secondary)
            }
            if model.needsReview || initialLoadFailed && !model.loaded {
                Button("native.routine.refresh") {
                    Task {
                        await model.load(connection: connection, agentID: agentID, acknowledgeReview: true)
                        guard isVisible, !Task.isCancelled else { return }
                        initialLoadFailed = !model.loaded
                        if !model.needsReview { showsActionError = false }
                    }
                }
                .disabled(model.isBusy || !connection.canSend)
            }
            if model.loaded && model.routines.isEmpty {
                ContentUnavailableView("native.routine.empty", systemImage: "clock", description: Text("native.routine.emptyHelp"))
                    .listRowBackground(Color.clear)
            }
            Section(agentName) {
            ForEach(model.routines) { routine in
                NavigationLink {
                    RoutineDetailScreen(connection: connection, model: model, agentID: agentID, routineID: routine.id)
                } label: {
                    RoutineSummaryRow(routine: routine)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if model.canManage {
                        Button {
                            let context = model.contextID
                            showsActionError = false
                            Task {
                                let confirmed = await model.setActive(routine, active: !routine.active, connection: connection)
                                guard isVisible, model.contextID == context else { return }
                                if confirmed { haptics.play(.selection) }
                                else { showsActionError = true; haptics.play(.warning) }
                            }
                        } label: {
                            Label(routine.active ? "native.routine.pause" : "native.routine.resume", systemImage: routine.active ? "pause" : "play")
                        }
                        .disabled(model.isBusy || model.needsReview || !connection.canSend)
                    }
                }
            }
            }
            if model.isBusy { ProgressView().frame(maxWidth: .infinity) }
        }
        .navigationTitle("native.routine.title")
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.canManage {
                    Button("native.routine.new", systemImage: "plus") { showsCreate = true }
                        .disabled(model.isBusy || model.needsReview || !connection.canSend)
                }
            }
        }
        .task(id: (connection.workspaceID ?? "") + ":" + agentID + ":" + String(connection.canSend)) {
            await model.load(connection: connection, agentID: agentID)
            guard isVisible, !Task.isCancelled else { return }
            initialLoadFailed = !model.loaded
        }
        .refreshable {
            await model.load(connection: connection, agentID: agentID, acknowledgeReview: true)
            guard isVisible, !Task.isCancelled else { return }
            if !model.needsReview { showsActionError = false }
        }
        .onChange(of: model.contextID) { _, _ in showsActionError = false; initialLoadFailed = false }
        .sheet(isPresented: $showsCreate) {
            NavigationStack { RoutineEditorScreen(connection: connection, model: model, agentID: agentID, draft: RoutineEditorDraft()) }
        }
    }
}

private struct RoutineSummaryRow: View {
    let routine: NativeRoutine

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(routine.name).font(.headline)
                Spacer()
                Text(routine.active ? "native.routine.active" : "native.routine.paused")
                    .font(.caption).foregroundStyle(routine.active ? .green : .secondary)
            }
            RoutineScheduleSummary(schedule: routine.schedule)
                .font(.subheadline).foregroundStyle(.secondary)
            if routine.active, let next = routine.nextRunAt.flatMap(RoutineClock.parse) {
                Text("native.routine.next \(next.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct RoutineDetailScreen: View {
    @Environment(AppHaptics.self) private var haptics
    @State private var isVisible = false
    let connection: AgentConnection
    let model: NativeRoutines
    let agentID: String
    let routineID: String
    @Environment(\.dismiss) private var dismiss
    @State private var showsEdit = false
    @State private var confirmsDelete = false
    @State private var showsActionError = false

    var body: some View {
        List {
            if let routine = model.routine(routineID) {
                Section {
                    RoutineSummaryRow(routine: routine)
                    Text(routine.instruction).textSelection(.enabled)
                    if let zone = TimeZone(identifier: routine.timezone)?.localizedName(for: .generic, locale: .current) {
                        LabeledContent("native.routine.timezone", value: zone)
                    }
                }
                Section {
                    if model.canManage {
                        Button(routine.active ? "native.routine.pause" : "native.routine.resume", systemImage: routine.active ? "pause" : "play") {
                            let context = model.contextID
                            showsActionError = false
                            Task {
                                let confirmed = await model.setActive(routine, active: !routine.active, connection: connection)
                                guard isVisible, model.contextID == context else { return }
                                if confirmed { haptics.play(.selection) }
                                else { showsActionError = true; haptics.play(.warning) }
                            }
                        }
                        Button("native.routine.runNow", systemImage: "play.circle") {
                            let context = model.contextID
                            showsActionError = false
                            Task {
                                let confirmed = await model.runNow(routine, connection: connection)
                                guard isVisible, model.contextID == context else { return }
                                if confirmed { haptics.play(.action) }
                                else { showsActionError = true; haptics.play(.warning) }
                            }
                        }
                        .accessibilityIdentifier("routine-run")
                        .disabled(model.hasUnfinishedRun(routineID))
                    }
                }
                .disabled(model.isBusy || model.needsReview || !connection.canSend)
                Section("native.routine.history") {
                    if let history = model.visibleRuns[routineID] {
                        if history.isEmpty && model.runs[routineID]?.isEmpty == true {
                            Text("native.routine.noRuns").foregroundStyle(.secondary)
                        }
                        ForEach(history) { run in RoutineRunRow(run: run) }
                    } else if model.isBusy { ProgressView() }
                    Button("native.routine.refreshHistory", systemImage: "arrow.clockwise") {
                        Task { await model.loadRuns(routineID, connection: connection) }
                    }
                    .disabled(model.isBusy || !connection.canSend)
                }
                if showsActionError { Text("native.error.generic").foregroundStyle(.secondary) }
                if model.needsReview {
                    Button("native.routine.refresh") {
                        Task {
                            await model.load(connection: connection, agentID: agentID, acknowledgeReview: true)
                            guard isVisible, !Task.isCancelled else { return }
                            if !model.needsReview { showsActionError = false }
                        }
                    }
                    .disabled(model.isBusy || !connection.canSend)
                }
                if model.canManage {
                    Section {
                        Button("native.routine.delete", role: .destructive) { confirmsDelete = true }
                            .disabled(model.isBusy || model.needsReview || !connection.canSend)
                    }
                }
            } else {
                ContentUnavailableView("native.routine.gone", systemImage: "clock.badge.xmark")
            }
        }
        .navigationTitle(model.routine(routineID)?.name ?? String(localized: "native.routine.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.canManage, model.routine(routineID) != nil {
                    Button("native.action.edit") { showsEdit = true }
                        .disabled(model.isBusy || model.needsReview || !connection.canSend)
                }
            }
        }
        .task(id: routineID) { await model.loadRuns(routineID, connection: connection) }
        .sheet(isPresented: $showsEdit) {
            if let routine = model.routine(routineID) {
                NavigationStack { RoutineEditorScreen(connection: connection, model: model, agentID: agentID, draft: RoutineEditorDraft(routine: routine)) }
            }
        }
        .confirmationDialog("native.routine.deleteWarning", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("native.routine.delete", role: .destructive) {
                guard let routine = model.routine(routineID) else { return }
                let context = model.contextID
                showsActionError = false
                Task {
                    let confirmed = await model.delete(routine, connection: connection)
                    guard isVisible, model.contextID == context else { return }
                    if confirmed { haptics.play(.success); dismiss() }
                    else { showsActionError = true; haptics.play(.warning) }
                }
            }
        }
    }
}

private struct RoutineRunRow: View {
    let run: NativeRoutineRun

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(run.title).font(.subheadline.weight(.medium))
                Spacer()
                Text(run.kind == "manual" ? "native.routine.manual" : "native.routine.scheduled")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let date = RoutineClock.parse(run.scheduledFor) {
                Text(date, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct RoutineEditorScreen: View {
    @Environment(AppHaptics.self) private var haptics
    @State private var isVisible = false
    let connection: AgentConnection
    let model: NativeRoutines
    let agentID: String
    @State private var draft: RoutineEditorDraft
    @State private var showsActionError = false
    @Environment(\.dismiss) private var dismiss
    private let contextID: Int

    init(connection: AgentConnection, model: NativeRoutines, agentID: String, draft: RoutineEditorDraft) {
        self.connection = connection; self.model = model; self.agentID = agentID
        _draft = State(initialValue: draft)
        contextID = model.contextID
    }

    var body: some View {
        Form {
            Section {
                TextField("native.routine.name", text: $draft.name)
                    .accessibilityIdentifier("routine-name")
                TextField("native.routine.instruction", text: $draft.instruction, axis: .vertical)
                    .accessibilityIdentifier("routine-instruction")
                    .lineLimit(4...12)
                Toggle("native.routine.active", isOn: $draft.active)
                    .accessibilityIdentifier("routine-active")
            }
            Section("native.routine.schedule") {
                if draft.original == nil || draft.original?.schedule != nil {
                    RoutineScheduleFields(draft: $draft.schedule, supportsOnce: model.supportsOnce)
                        .onChange(of: draft.schedule) { _, _ in draft.scheduleChanged = true }
                } else {
                    Text("native.routine.automatic")
                }
            }
            if let zone = TimeZone(identifier: draft.timezone)?.localizedName(for: .generic, locale: .current) {
                Section { LabeledContent("native.routine.timezone", value: zone) }
            }
            if model.supportsRecovery { RoutinePolicyFields(missed: $draft.missedPolicy) }
            if let validation = draft.validation { Text(validation).font(.caption).foregroundStyle(.secondary) }
            if showsActionError { Text("native.error.generic").foregroundStyle(.secondary) }
            if model.needsReview {
                Button("native.routine.refresh") {
                    Task {
                        await model.load(connection: connection, agentID: agentID, acknowledgeReview: true)
                        guard isVisible, model.contextID == contextID, !Task.isCancelled else { return }
                        if !model.needsReview { dismiss() }
                    }
                }
                .disabled(model.isBusy || !connection.canSend)
            }
            if model.isBusy { ProgressView().frame(maxWidth: .infinity) }
        }
        .navigationTitle(draft.original == nil ? "native.routine.new" : "native.routine.edit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("native.action.cancel") { dismiss() }
                    .disabled(model.isBusy)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("native.action.save") {
                    let changed = draft.original == nil || !draft.changes.isEmpty
                    showsActionError = false
                    Task {
                        let confirmed = await model.save(draft, connection: connection)
                        guard isVisible, model.contextID == contextID else { return }
                        if confirmed {
                            if changed { haptics.play(.success) }
                            dismiss()
                        } else { showsActionError = true; haptics.play(.warning) }
                    }
                }
                    .accessibilityIdentifier("routine-save")
                    .disabled(draft.validation != nil || model.isBusy || model.needsReview || !connection.canSend)
            }
        }
        .interactiveDismissDisabled(model.isBusy)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .onChange(of: model.contextID) { _, current in if current != contextID { dismiss() } }
    }
}

private struct RoutinePolicyFields: View {
    @Binding var missed: String

    var body: some View {
        Section {
            Picker("native.routine.whenMissed", selection: $missed) {
                Text("native.routine.skip").tag("skip")
                Text("native.routine.runLatest").tag("run-once")
            }
        }
    }
}

private struct RoutineScheduleFields: View {
    @Binding var draft: RoutineScheduleDraft
    let supportsOnce: Bool

    private var kinds: [RoutineScheduleKind] { RoutineScheduleKind.allCases.filter {
        ($0 != .once || supportsOnce || draft.kind == .once) && ($0 != .custom || !draft.expression.isEmpty)
    } }

    var body: some View {
        Picker("native.routine.frequency", selection: $draft.kind) {
            ForEach(kinds) { kind in Text(kind.title).tag(kind) }
        }
        switch draft.kind {
        case .hourly:
            Stepper("native.routine.minute \(draft.minute)", value: $draft.minute, in: 0...59)
        case .daily, .weekdays:
            RoutineTimeField(time: $draft.time)
        case .weekly:
            Picker("native.routine.weekday", selection: $draft.weekday) {
                ForEach(RoutineNamedDay.weekdays) { day in Text(day.name).tag(day.id) }
            }
            RoutineTimeField(time: $draft.time)
        case .monthly:
            Stepper("native.routine.monthDay \(draft.day)", value: $draft.day, in: 1...31)
            RoutineTimeField(time: $draft.time)
        case .interval:
            RoutineIntervalFields(amount: $draft.amount, unit: $draft.unit, allowsDays: true)
            if draft.unparsedAnchor != nil {
                Button("native.routine.replaceAnchor") { draft.replaceUnparsedAnchor() }
            } else {
                DatePicker("native.routine.anchor", selection: $draft.anchorAt)
            }
        case .advanced:
            RoutineAdvancedFields(draft: $draft)
        case .custom:
            Text("native.routine.schedule.custom").foregroundStyle(.secondary)
        case .once:
            RoutineDateField(date: $draft.date)
            RoutineTimeField(time: $draft.time)
        }
    }
}

private struct RoutineIntervalFields: View {
    @Binding var amount: Int
    @Binding var unit: String
    let allowsDays: Bool

    var body: some View {
        TextField("native.routine.every", value: $amount, format: .number)
            .keyboardType(.numberPad)
        Picker("native.routine.unit", selection: $unit) {
            Text("native.routine.minutes").tag("minutes")
            Text("native.routine.hours").tag("hours")
            if allowsDays { Text("native.routine.days").tag("days") }
        }
    }
}

private struct RoutineAdvancedFields: View {
    @Binding var draft: RoutineScheduleDraft

    var body: some View {
        DisclosureGroup("native.routine.months") {
            ForEach(RoutineNamedDay.months) { month in
                Toggle(month.name, isOn: RoutineSelection.binding(month.id, in: $draft.months))
            }
        }
        Picker("native.routine.onDays", selection: $draft.dayKind) {
            Text("native.routine.everyDay").tag("every-day")
            Text("native.routine.weekDays").tag("days-of-week")
            Text("native.routine.monthDays").tag("days-of-month")
        }
        .onChange(of: draft.dayKind) { _, _ in draft.selectedDays = [] }
        if draft.dayKind == "days-of-week" {
            ForEach(RoutineNamedDay.weekdays) { day in
                Toggle(day.name, isOn: RoutineSelection.binding(day.id, in: $draft.selectedDays))
            }
        } else if draft.dayKind == "days-of-month" {
            DisclosureGroup("native.routine.monthDays") {
                ForEach(1...31, id: \.self) { day in
                    Toggle(day.formatted(), isOn: RoutineSelection.binding(day, in: $draft.selectedDays))
                }
            }
        }
        Picker("native.routine.timing", selection: $draft.timeKind) {
            Text("native.routine.atTime").tag("at-time")
            Text("native.routine.intervalEvery").tag("every")
        }
        if draft.timeKind == "at-time" { RoutineTimeField(time: $draft.time) }
        else { RoutineIntervalFields(amount: $draft.advancedAmount, unit: $draft.advancedUnit, allowsDays: false) }
    }
}

private enum RoutineSelection {
    static func binding(_ id: Int, in values: Binding<Set<Int>>) -> Binding<Bool> {
        Binding(get: { values.wrappedValue.contains(id) }, set: { selected in
            if selected { values.wrappedValue.insert(id) } else { values.wrappedValue.remove(id) }
        })
    }
}

private struct RoutineNamedDay: Identifiable {
    let id: Int
    let name: String
    static var weekdays: [Self] { Calendar.current.weekdaySymbols.enumerated().map { Self(id: $0.offset, name: $0.element) } }
    static var months: [Self] { Calendar.current.monthSymbols.enumerated().map { Self(id: $0.offset + 1, name: $0.element) } }
}

private struct RoutineTimeField: View {
    @Binding var time: String

    var body: some View {
        DatePicker("native.routine.time", selection: Binding(get: {
            RoutineClock.instant(date: "2000-01-01", time: time, timezone: "GMT") ?? .now
        }, set: { value in
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = RoutineClock.utc
            let parts = calendar.dateComponents([.hour, .minute], from: value)
            time = String(format: "%02d:%02d", parts.hour ?? 9, parts.minute ?? 0)
        }), displayedComponents: .hourAndMinute)
        .environment(\.timeZone, RoutineClock.utc)
    }
}

private struct RoutineDateField: View {
    @Binding var date: String

    var body: some View {
        DatePicker("native.routine.date", selection: Binding(get: {
            RoutineClock.instant(date: date, time: "12:00", timezone: "GMT") ?? .now
        }, set: { date = RoutineClock.dateString($0) }), displayedComponents: .date)
        .environment(\.timeZone, RoutineClock.utc)
    }
}

private struct RoutineScheduleSummary: View {
    let schedule: WireValue?

    var body: some View {
        if let schedule, let kind = schedule["kind"]?.string, let named = RoutineScheduleKind(rawValue: kind) {
            switch named {
            case .daily:
                Text("native.routine.summary.daily \(schedule["time"]?.string ?? "")")
            case .weekdays:
                Text("native.routine.summary.weekdays \(schedule["time"]?.string ?? "")")
            case .weekly:
                let day = RoutineNamedDay.weekdays.first { $0.id == schedule["weekday"]?.integer }?.name ?? ""
                Text("native.routine.summary.weekly \(day) \(schedule["time"]?.string ?? "")")
            case .monthly:
                Text("native.routine.summary.monthly \(schedule["day"]?.integer ?? 1) \(schedule["time"]?.string ?? "")")
            case .hourly:
                Text("native.routine.summary.hourly \(String(format: "%02d", schedule["minute"]?.integer ?? 0))")
            case .interval:
                let amount = schedule["amount"]?.integer ?? 1
                switch schedule["unit"]?.string {
                case "minutes": Text("native.routine.summary.minutes \(amount)")
                case "days":
                    if amount == 1 { Text("native.routine.summary.day") }
                    else { Text("native.routine.summary.days \(amount)") }
                default:
                    if amount == 1 { Text("native.routine.summary.hour") }
                    else { Text("native.routine.summary.hours \(amount)") }
                }
            case .once:
                Text("native.routine.summary.once \(schedule["date"]?.string ?? "") \(schedule["time"]?.string ?? "")")
            case .custom: Text(named.title)
            case .advanced: Text(named.title)
            }
        } else { Text("native.routine.automatic") }
    }
}
