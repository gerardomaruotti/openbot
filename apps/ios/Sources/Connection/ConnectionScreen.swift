import SwiftUI

struct ConnectionScreen: View {
    let connection: AgentConnection
    let notifications: NativeNotifications
    var queuedCount = 0
    var incomingLink: String? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppHaptics.preferenceKey) private var hapticsEnabled = true
    @State private var email = ""
    @State private var challenge: String?
    @State private var code = ""
    @State private var link = ""
    @State private var usesLink = false
    @State private var confirmsSignOut = false
    @State private var showsActionProblem = false
    @State private var performingAction = false
    @State private var actionID = UUID()
    @State private var isVisible = false

    private enum ActionResult {
        case completed, failed
        case challenge(String, String?)
    }

    var body: some View {
        NavigationStack {
            Form {
                if connection.isAuthenticated {
                    Section {
                        Text(connection.email).privacySensitive()
                    }
                    Section("native.connection.macs") {
                        ForEach(connection.hosts) { host in
                            Button {
                                perform {
                                    await connection.reconnect(hostID: host.hostId)
                                    return connection.problem == nil ? .completed : .failed
                                }
                            } label: {
                                HStack {
                                    Label(host.name, systemImage: "desktopcomputer")
                                    Spacer()
                                    if connection.phase == .online && connection.hostID == host.hostId { Image(systemName: "checkmark") }
                                }
                            }
                            .disabled(connection.isBusy || performingAction)
                        }
                        Button("native.connection.reconnect", systemImage: "arrow.clockwise") {
                            perform {
                                await connection.reconnect()
                                return connection.problem == nil ? .completed : .failed
                            }
                        }
                        .disabled(connection.isBusy || performingAction)
                    }
                    Section {
                        Button("native.connection.signOut", role: .destructive) {
                            confirmsSignOut = true
                        }
                        .disabled(connection.isBusy || performingAction)
                    }
                } else if usesLink {
                    Section {
                        SecureField("native.connection.link", text: $link)
                            .textContentType(.oneTimeCode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .disabled(connection.isBusy || performingAction)
                        Button("native.connection.connect") {
                            let value = link
                            perform {
                                await connection.pair(value)
                                return connection.problem == nil ? .completed : .failed
                            }
                        }
                        .disabled(link.isEmpty || connection.isBusy || performingAction)
                    } footer: { Text("native.connection.linkHelp") }
                    Button("native.connection.useEmail") { usesLink = false; showsActionProblem = false }
                        .disabled(connection.isBusy || performingAction)
                } else if let challenge {
                    Section {
                        SecureField("native.connection.code", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .disabled(connection.isBusy || performingAction)
                        Button("native.connection.connect") {
                            let value = code
                            perform {
                                await connection.verifyEmail(challenge: challenge, code: value)
                                return connection.problem == nil ? .completed : .failed
                            }
                        }
                        .disabled(code.isEmpty || connection.isBusy || performingAction)
                    } footer: { Text("native.connection.codeHelp") }
                    Button("native.connection.changeEmail") { self.challenge = nil; code = ""; showsActionProblem = false }
                        .disabled(connection.isBusy || performingAction)
                } else {
                    Section {
                        TextField("native.connection.email", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(connection.isBusy || performingAction)
                        Button("native.connection.continue") {
                            let address = email
                            perform {
                                guard let (challenge, developmentCode) = await connection.startEmail(address) else { return .failed }
                                return .challenge(challenge, developmentCode)
                            }
                        }
                        .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || connection.isBusy || performingAction)
                    } footer: { Text("native.connection.emailHelp") }
                    Button("native.connection.useLink") { usesLink = true; showsActionProblem = false }
                        .disabled(connection.isBusy || performingAction)
                }
                if connection.isAuthenticated { NotificationSettingsSection(notifications: notifications) }
                Section {
                    Toggle("native.haptics.enabled", isOn: $hapticsEnabled)
                        .accessibilityIdentifier("app-haptics")
                }
                if performingAction { ProgressView().frame(maxWidth: .infinity).accessibilityLabel("native.connection.connecting") }
                if showsActionProblem { Text("native.error.generic").foregroundStyle(.red) }
            }
            .navigationTitle("native.connection.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("native.action.done") { dismiss() }
                }
            }
            .onAppear { isVisible = true; showsActionProblem = false }
            .task(id: incomingLink) {
                guard let incomingLink else { return }
                link = incomingLink; usesLink = true
                perform {
                    await connection.pair(incomingLink)
                    return connection.phase == .online ? .completed : .failed
                }
            }
            .onDisappear { isVisible = false; actionID = UUID(); performingAction = false; showsActionProblem = false }
            .onChange(of: scenePhase) { _, phase in if phase != .active { showsActionProblem = false } }
            .onChange(of: connection.phase) { _, phase in if phase == .online { dismiss() } }
            .onChange(of: connection.isAuthenticated) { _, authenticated in
                if !authenticated {
                    email = ""; challenge = nil; code = ""; link = ""; usesLink = false
                }
            }
            .confirmationDialog("native.connection.signOutConfirm", isPresented: $confirmsSignOut, titleVisibility: .visible) {
                Button("native.connection.signOut", role: .destructive) {
                    perform {
                        await connection.signOut()
                        return connection.problem == nil && connection.signOutNotice == nil && notifications.problem == nil ? .completed : .failed
                    }
                }
            } message: {
                Text("native.connection.signOutLocalData")
            }
        }
    }

    private func perform(_ operation: @escaping @MainActor () async -> ActionResult) {
        guard !performingAction else { return }
        let request = UUID()
        actionID = request
        showsActionProblem = false
        performingAction = true
        Task { @MainActor in
            let result = await operation()
            guard isVisible, actionID == request else { return }
            performingAction = false
            switch result {
            case .challenge(let value, let developmentCode):
                challenge = value
                code = developmentCode ?? ""
            case .completed:
                break
            case .failed:
                showsActionProblem = scenePhase == .active
            }
        }
    }
}
