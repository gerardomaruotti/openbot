import SwiftUI

struct QuestionCard: View {
    let prompt: AgentQuestionPrompt
    let available: Bool
    let responding: Bool
    let respond: ([String: [String]]) async -> Bool

    var body: some View {
        if let confirmation = prompt.confirmation {
            ConfirmationQuestionCard(confirmation: confirmation, available: available, responding: responding, respond: respond)
                .id(prompt.contextID)
        } else {
            QuestionFormCard(prompt: prompt, available: available, responding: responding, respond: respond)
                .id(prompt.contextID)
        }
    }
}

private struct QuestionFormCard: View {
    let prompt: AgentQuestionPrompt
    let available: Bool
    let responding: Bool
    let respond: ([String: [String]]) async -> Bool
    @State private var choices: [String: Set<String>] = [:]
    @State private var text: [String: String] = [:]
    @State private var submitted = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppHaptics.self) private var haptics

    private var answers: [String: [String]] {
        var result: [String: [String]] = [:]
        for question in prompt.questions {
            let selected = (question.options ?? []).map(\.label).filter { choices[question.id, default: []].contains($0) }
            let extra = text[question.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            result[question.id] = selected + (extra.isEmpty ? [] : [extra])
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("native.question.title", systemImage: "questionmark.bubble")
                .font(.headline)
            ForEach(prompt.questions) { question in
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.question).font(.callout.weight(.medium)).textSelection(.enabled)
                    ForEach(question.options ?? [], id: \.label) { option in
                        Button {
                            let previous = choices[question.id, default: []]
                            if question.multiSelect == true {
                                if choices[question.id, default: []].contains(option.label) { choices[question.id]?.remove(option.label) }
                                else { choices[question.id, default: []].insert(option.label) }
                            } else { choices[question.id] = [option.label]; text[question.id] = "" }
                            if previous != choices[question.id, default: []] { haptics.play(.selection) }
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: choices[question.id, default: []].contains(option.label) ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(option.label)
                                    if !option.description.isEmpty { Text(option.description).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(choices[question.id, default: []].contains(option.label) ? .isSelected : [])
                    }
                    if question.isSecret {
                        SecureField("native.question.privateAnswer", text: answerBinding(question))
                            .privacySensitive()
                            .textContentType(.oneTimeCode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                    } else {
                        TextField(question.options?.isEmpty == false ? "native.question.otherAnswer" : "native.question.answer", text: answerBinding(question), axis: .vertical)
                            .lineLimit(1...5)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            HStack {
                Button("native.question.cancel", role: .cancel) { submit([:]) }
                    .buttonStyle(.bordered)
                Button("native.question.submit") { submit(answers) }
                    .buttonStyle(.borderedProminent)
                    .disabled(answers.values.allSatisfy(\.isEmpty))
                if responding { ProgressView() }
            }
        }
        .disabled(!available || responding || submitted)
        .font(.callout)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 20))
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { clearSecrets() }
        }
        .onDisappear { clearSecrets() }
    }

    private func answerBinding(_ question: AgentQuestionPrompt.Question) -> Binding<String> {
        Binding(get: { text[question.id, default: ""] }, set: { value in
            text[question.id] = value
            if question.multiSelect != true && !value.isEmpty { choices[question.id] = [] }
        })
    }

    private func submit(_ answers: [String: [String]]) {
        Task {
            submitted = true
            let confirmed = await respond(answers)
            clearSecrets()
            submitted = confirmed
        }
    }

    private func clearSecrets() {
        for question in prompt.questions where question.isSecret { text[question.id] = nil; choices[question.id] = nil }
    }
}

private struct ConfirmationQuestionCard: View {
    let confirmation: AgentConfirmation
    let available: Bool
    let responding: Bool
    let respond: ([String: [String]]) async -> Bool
    @State private var selected: [String: String] = [:]
    @State private var submitted = false
    @State private var confirming: AgentConfirmation.Action?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("native.confirmation.title", systemImage: "checkmark.bubble")
                .font(.headline)
            Text(confirmation.title).font(.headline).textSelection(.enabled)
            if confirmation.danger {
                Label("native.confirmation.danger", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            ForEach(confirmation.fields) { field in
                ConfirmationFieldRow(field: field, selection: Binding(
                    get: { field.select.flatMap { selected[$0] } ?? field.options.first ?? "" },
                    set: { if let key = field.select { selected[key] = $0 } }
                ))
            }
            if let preview = confirmation.preview, !preview.isEmpty {
                ConfirmationPreview(text: preview)
            }
            if confirmation.continuesAutomatically {
                Text("native.confirmation.autoAction").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(confirmation.actions) { action in
                ConfirmationActionButton(action: action, held: confirmation.requiresHold(action),
                                         holdSeconds: confirmation.holdSeconds,
                                         perform: { submit(action) },
                                         confirm: { confirming = action })
            }
            Button("native.question.cancel", role: .cancel) { submit(nil) }
                .buttonStyle(.bordered)
            if responding { ProgressView() }
        }
        .disabled(!available || responding || submitted)
        .font(.callout)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 20))
        .confirmationDialog("native.confirmation.confirmAction \(confirming?.label ?? "")",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible) {
            if let action = confirming {
                Button("native.confirmation.confirm", role: action.style == "danger" ? .destructive : nil) {
                    confirming = nil
                    submit(action)
                }
            }
            Button("native.action.cancel", role: .cancel) { confirming = nil }
        }
    }

    private func submit(_ action: AgentConfirmation.Action?) {
        guard available, !responding, !submitted else { return }
        var answers: [String: [String]] = [:]
        if let action {
            answers["action"] = [action.label]
            for field in confirmation.fields {
                if let key = field.select { answers[key] = [selected[key] ?? field.options.first ?? ""] }
            }
        }
        submitted = true
        let response = answers
        Task { submitted = await respond(response) }
    }
}

private struct ConfirmationFieldRow: View {
    let field: AgentConfirmation.Field
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if field.select != nil {
                Picker(field.label, selection: $selection) {
                    ForEach(field.options, id: \.self) { option in Text(option).tag(option) }
                }
                .pickerStyle(.menu)
            } else {
                Text(field.label).font(.caption).foregroundStyle(.secondary)
                Text(field.value ?? "").textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ConfirmationPreview: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("native.confirmation.preview").font(.caption).foregroundStyle(.secondary)
            // Keep all supplied text. Markdown is shown as plain text, with no embedded navigation or HTML.
            Text(text).textSelection(.enabled).lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ConfirmationActionButton: View {
    let action: AgentConfirmation.Action
    let held: Bool
    let holdSeconds: Double
    let perform: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(role: action.style == "danger" ? .destructive : nil) {
                if held || action.confirm == true { confirm() } else { perform() }
            } label: {
                Text(action.label).frame(maxWidth: .infinity)
                    .fontWeight(action.style == "primary" || action.style == "danger" ? .semibold : .regular)
            }
            .buttonStyle(.bordered)
            .tint(action.style == "danger" ? .red : .accentColor)
            .modifier(ConfirmationHoldGesture(enabled: held, seconds: holdSeconds, perform: perform))
            if held {
                Text("native.confirmation.hold").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ConfirmationHoldGesture: ViewModifier {
    let enabled: Bool
    let seconds: Double
    let perform: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.highPriorityGesture(LongPressGesture(minimumDuration: seconds).onEnded { _ in perform() })
        } else { content }
    }
}
