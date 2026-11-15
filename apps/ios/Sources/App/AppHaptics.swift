import Observation
import SwiftUI
import UIKit

/// App-owned feedback for discrete user actions. Native controls keep their
/// system feedback; network events and streamed text do not emit app feedback.
@Observable
@MainActor
final class AppHaptics {
    static let preferenceKey = "native.haptics.enabled"

    nonisolated enum Kind: Equatable {
        case selection, action, success, warning, error

        var feedback: SensoryFeedback {
            switch self {
            case .selection: .selection
            // A soft pulse accompanies the new message bubble or accepted action.
            // It does not claim that the host delivered or completed the request.
            case .action: .impact(flexibility: .soft, intensity: 0.45)
            case .success: .success
            case .warning: .warning
            case .error: .error
            }
        }
    }

    nonisolated struct Event: Equatable {
        let kind: Kind
        let id = UUID()
    }

    private(set) var event: Event?

    func play(_ kind: Kind) {
        guard UIApplication.shared.applicationState == .active,
              UserDefaults.standard.object(forKey: Self.preferenceKey) as? Bool != false else { return }
        event = Event(kind: kind)
    }

    func discard() { event = nil }
}

/// One stable scene owner allows an acknowledged save to give feedback even
/// when its editor closes in the same transaction. Callers own action validity
/// and suppress results after leaving their originating screen or context.
struct AppHapticsHost: ViewModifier {
    @State private var haptics = AppHaptics()
    @AppStorage(AppHaptics.preferenceKey) private var enabled = true
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .environment(haptics)
            .sensoryFeedback(trigger: haptics.event) { _, event in
                enabled && scenePhase == .active ? event?.kind.feedback : nil
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { haptics.discard() } }
            .onChange(of: enabled) { _, enabled in if !enabled { haptics.discard() } }
    }
}
