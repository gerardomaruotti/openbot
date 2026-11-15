import SwiftUI

struct BrowserHandoffCard: View {
    let handoff: AgentBrowserHandoff
    let available: Bool
    let responding: Bool
    let problem: LocalizedStringResource?
    let cancel: () -> Void
    var open: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if open == nil { Label("native.handoff.title", systemImage: "desktopcomputer").font(.headline) }
            else { Label("native.browser.handoffTitle", systemImage: "safari").font(.headline) }
            if let site = handoff.site { Text(site).fontWeight(.medium).textSelection(.enabled) }
            if open == nil {
                Text(handoff.instruction)
            } else { Text("native.browser.handoffBody").foregroundStyle(.secondary) }
            if problem != nil { Text("native.error.generic").foregroundStyle(.red) }
            HStack(spacing: 12) {
                if let open { Button("native.browser.open", systemImage: "safari", action: open).buttonStyle(.borderedProminent) }
                Button("native.handoff.cancel", role: .cancel, action: cancel)
                    .buttonStyle(.bordered)
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
}

