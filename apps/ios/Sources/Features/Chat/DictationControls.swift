import AVFAudio
import SwiftUI
import UIKit

/// The caller supplies a conversation/account context and inserts text only after explicit review.
struct DictationSheet: View {
    let contextID: String
    let onInsert: (String) -> Void
    let onCancel: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @State private var dictation = NativeDictation()
    @State private var finished = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Label {
                        if dictation.phase == .recording { Text("native.dictation.recording") }
                        else { Text("native.dictation.title") }
                    } icon: { Image(systemName: "waveform") }
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(dictation.phase == .recording ? .red : .primary)
                        .accessibilityIdentifier("dictation.status")
                    if dictation.phase == .authorizing {
                        ProgressView("native.dictation.preparing")
                    } else if dictation.phase == .finishing {
                        ProgressView("native.dictation.finishing")
                    }
                    if !dictation.transcript.isEmpty {
                        Text(dictation.transcript)
                            .font(.title3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("dictation.transcript")
                    }
                    if let problem = dictation.problem {
                        Text(problem).font(.callout).foregroundStyle(.secondary)
                    }
                    if dictation.phase == .recording {
                        Button("native.dictation.stop", systemImage: "stop.fill") { dictation.stop() }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .accessibilityIdentifier("dictation.stop")
                    } else if dictation.phase == .review {
                        if dictation.canOpenSettings {
                            Button("native.capture.openSettings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                        } else {
                            Button("native.dictation.retry") {
                                Task { guard !finished else { return }; await dictation.start(locale: locale) }
                            }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(24)
            }
            .navigationTitle("native.dictation.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("native.capture.cancel", role: .cancel) { cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("native.dictation.insert") {
                        guard !finished, dictation.phase == .review else { return }
                        let text = dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        finished = true
                        dictation.cancel()
                        onInsert(text)
                    }
                    .disabled(dictation.phase != .review || dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("dictation.insert")
                }
            }
        }
        .task {
            guard !finished else { return }
            guard scenePhase != .background else { cancel(); return }
            await dictation.start(locale: locale)
        }
        .onChange(of: contextID) { _, _ in cancel() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { cancel() } }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).receive(on: RunLoop.main)) { notification in
            if let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
               AVAudioSession.InterruptionType(rawValue: raw) == .began {
                dictation.interrupted()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main)) { notification in
            if let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
               let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
               reason == .oldDeviceUnavailable || reason == .noSuitableRouteForCategory {
                dictation.interrupted()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVAudioEngineConfigurationChange).receive(on: RunLoop.main)) { notification in
            dictation.configurationChanged(notification)
        }
        .onDisappear { finished = true; dictation.cancel() }
    }

    private func cancel() {
        guard !finished else { return }
        finished = true
        dictation.cancel()
        onCancel()
    }
}
