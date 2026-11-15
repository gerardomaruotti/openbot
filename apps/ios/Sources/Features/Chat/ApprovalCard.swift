import SwiftUI

struct ApprovalCard: View {
    let approval: AgentApproval
    let available: Bool
    let responding: Bool
    let respond: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("native.approval.title", systemImage: "hand.raised")
                .font(.headline)
            if let reason = approval.reason { Text(reason) }
            if let command = approval.command {
                Text(command).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            }
            if let cwd = approval.cwd { detail("native.approval.folder", value: cwd) }
            if let root = approval.grantRoot { detail("native.approval.access", value: root) }
            if let permissions = approval.permissions {
                if !permissions.fileSystem.read.isEmpty {
                    detail("native.approval.read", value: permissions.fileSystem.read.joined(separator: "\n"))
                }
                if !permissions.fileSystem.write.isEmpty {
                    detail("native.approval.write", value: permissions.fileSystem.write.joined(separator: "\n"))
                }
                if permissions.network { Label("native.approval.network", systemImage: "network") }
            }
            if approval.truncated { Text("native.approval.truncated").foregroundStyle(.secondary) }
            HStack(spacing: 12) {
                Button("native.approval.decline", role: .destructive) { respond(false) }
                    .buttonStyle(.bordered)
                Button("native.approval.allow") { respond(true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(approval.truncated)
                if responding { ProgressView() }
            }
            .disabled(!available || responding)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .contain)
    }

    private func detail(_ title: LocalizedStringResource, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
