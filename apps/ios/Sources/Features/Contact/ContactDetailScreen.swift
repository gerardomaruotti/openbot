import SwiftUI

struct ContactDetailScreen: View {
    let store: ConversationStore
    let conversationID: String
    @Environment(\.dismiss) private var dismiss
    @State private var tab = ContactTab.info
    @State private var isEditing = false
    @State private var nameDraft = ""
    @State private var confirmsBlock = false
    @State private var showsUnavailable = false

    private var conversation: Conversation? { store.conversation(conversationID) }

    var body: some View {
        if let conversation {
            ScrollView {
                VStack(spacing: 20) {
                    contactHeading(conversation)
                    if store.isLive {
                        LiveAgentDetails(store: store, conversation: conversation)
                    } else if tab == .info {
                        information(conversation)
                    } else {
                        backgrounds(conversation)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(MessagesStyle.surface)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    GlassIconButton(symbol: "chevron.backward", label: "native.action.back") { dismiss() }
                    Spacer()
                    if !store.isLive { GlassTextButton(title: "native.action.edit") { nameDraft = conversation.name; isEditing = true } }
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 2)
            }
            .sheet(isPresented: $isEditing) { editSheet }
            .confirmationDialog(conversation.isBlocked ? "native.contact.unblockTitle" : "native.contact.blockTitle", isPresented: $confirmsBlock, titleVisibility: .visible) {
                Button(conversation.isBlocked ? "native.contact.unblock" : "native.contact.block", role: .destructive) {
                    store.update(conversationID) { $0.isBlocked.toggle() }
                }
            }
            .alert("native.error.generic", isPresented: $showsUnavailable) {
                Button("native.action.done", role: .cancel) { }
            }
        }
    }

    private func contactHeading(_ conversation: Conversation) -> some View {
        VStack(spacing: 8) {
            AvatarView(asset: conversation.avatar, size: 80)
            Text(conversation.name)
                .font(.title.bold())
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.75)
            if !store.isLive {
            HStack(spacing: 20) {
                contactAction("phone.fill", label: "native.contact.call")
                contactAction("video.fill", label: "native.contact.video")
                Button { } label: {
                    Image(systemName: "envelope.fill")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 48, height: 48)
                        .background(MessagesStyle.card, in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(true)
                .accessibilityLabel("native.contact.email")
            }
            .padding(.top, 7)

            HStack(spacing: 4) {
                ForEach(ContactTab.allCases) { item in
                    Button { tab = item } label: {
                        Text(item.title)
                            .font(.subheadline.weight(tab == item ? .semibold : .regular))
                            .foregroundStyle(tab == item ? .primary : .secondary)
                            .padding(.horizontal, 16)
                            .frame(height: 35)
                    }
                    .buttonStyle(.plain)
                    .background {
                        if tab == item { Capsule().fill(.clear).glassEffect(.regular.interactive(), in: .capsule) }
                    }
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 6)
            } else {
                Text("native.connection.agent").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 16)
            }
        }
        .padding(.top, -48)
    }

    @ViewBuilder
    private func information(_ conversation: Conversation) -> some View {
        if let phone = conversation.phone {
            DetailCard {
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 5) {
                            Text("native.contact.phone").font(.caption).foregroundStyle(.secondary)
                            Text("native.contact.recent")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(.secondary, in: .rect(cornerRadius: 2))
                        }
                        Text(phone).font(.body)
                    }
                    Spacer()
                    Image(systemName: "phone.fill").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }

            DetailCard {
                VStack(spacing: 0) {
                    Button("native.contact.create") { nameDraft = conversation.name; isEditing = true }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 15.5)
                    Divider()
                    Button("native.contact.addExisting") { nameDraft = conversation.name; isEditing = true }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 15.5)
                }
                .padding(.horizontal, 20)
            }
        }

        DetailCard {
            VStack(spacing: 0) {
                Toggle("native.action.hideAlerts", isOn: setting(\.isMuted))
                    .padding(.vertical, 11.5)
                Divider()
                Toggle("native.contact.readReceipts", isOn: setting(\.sendsReadReceipts))
                    .padding(.vertical, 11.5)
            }
            .tint(.green)
            .padding(.horizontal, 20)
        }

        DetailCard {
            Toggle("native.contact.translate", isOn: setting(\.translatesAutomatically))
                .tint(.green)
                .padding(.horizontal, 20)
                .padding(.vertical, 11.5)
        }

        DetailCard {
            Button(conversation.isBlocked ? "native.contact.unblock" : "native.contact.block", role: .destructive) { confirmsBlock = true }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
        }

        DetailCard {
            Text("native.contact.verify")
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
        }
    }

    private func backgrounds(_ conversation: Conversation) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
            ForEach(ChatBackground.allCases) { background in
                Button {
                    store.update(conversationID) { $0.background = background }
                } label: {
                    VStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 24)
                            .fill(background.color)
                            .frame(height: 160)
                            .overlay {
                                RoundedRectangle(cornerRadius: 24).stroke(conversation.background == background ? MessagesStyle.accent : .secondary.opacity(0.2), lineWidth: conversation.background == background ? 3 : 1)
                            }
                        Text(background.title).font(.subheadline).foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func contactAction(_ symbol: String, label: LocalizedStringResource) -> some View {
        Button { showsUnavailable = true } label: {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.primary)
                .frame(width: 48, height: 48)
                .background(MessagesStyle.card, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    private func setting(_ keyPath: WritableKeyPath<Conversation, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.conversation(conversationID)?[keyPath: keyPath] ?? false },
            set: { newValue in store.update(conversationID) { $0[keyPath: keyPath] = newValue } }
        )
    }

    private var editSheet: some View {
        NavigationStack {
            Form {
                TextField("native.contact.name", text: $nameDraft)
                    .textContentType(.name)
            }
            .navigationTitle("native.contact.editTitle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("native.action.cancel") { isEditing = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("native.action.done") {
                        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty { store.update(conversationID) { $0.name = name } }
                        isEditing = false
                    }
                    .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private enum ContactTab: String, CaseIterable, Identifiable {
    case info, backgrounds
    var id: Self { self }
    var title: LocalizedStringResource {
        switch self {
        case .info: "native.contact.info"
        case .backgrounds: "native.contact.backgrounds"
        }
    }
}

private struct DetailCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.body)
            .frame(maxWidth: .infinity)
            .background(MessagesStyle.card, in: .rect(cornerRadius: 26))
    }
}
