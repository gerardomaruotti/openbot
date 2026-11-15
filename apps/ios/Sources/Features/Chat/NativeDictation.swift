import AVFAudio
import Foundation
import Observation
import Speech

/// A short, on-device dictation session. Text is transient until the person adds it to their draft.
@Observable
@MainActor
final class NativeDictation {
    enum Phase { case idle, authorizing, recording, finishing, review }

    private(set) var phase: Phase = .idle
    private(set) var transcript = ""
    private(set) var problem: LocalizedStringResource?
    private(set) var canOpenSettings = false
    private var generation = 0
    private var engine: AVAudioEngine?
    private var audio: DictationAudioSink?
    private var recognizer: SFSpeechRecognizer?
    private var recognition: SFSpeechRecognitionTask?
    private var limit: Task<Void, Never>?
    private var hasTap = false
    private var ownsAudioSession = false

    func start(locale: Locale = .current) async {
        guard phase != .authorizing, phase != .recording, phase != .finishing else { return }
        cancel()
        let epoch = generation
        phase = .authorizing
        let speech = await Self.speechPermission()
        guard epoch == generation, !Task.isCancelled else { return }
        guard speech == .authorized else {
            canOpenSettings = speech == .denied
            fail(speech == .restricted ? "native.dictation.restricted" : "native.dictation.speechDenied")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            fail("native.error.generic"); return
        }
        let microphone = await AVAudioApplication.requestRecordPermission()
        guard epoch == generation, !Task.isCancelled else { return }
        guard microphone else {
            canOpenSettings = AVAudioApplication.shared.recordPermission == .denied
            fail("native.dictation.microphoneDenied"); return
        }
        guard recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            fail("native.error.generic"); return
        }
        do {
            self.recognizer = recognizer
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            ownsAudioSession = true
            let engine = AVAudioEngine()
            self.engine = engine
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                fail("native.error.generic"); return
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            request.taskHint = .dictation
            let audio = DictationAudioSink(request)
            self.audio = audio
            Self.installTap(input, format: format, audio: audio)
            hasTap = true
            // Keep this callback nonisolated. Speech can deliver results on its own queue.
            let receive: @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void = { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal == true
                let failed = error != nil
                Task { @MainActor [weak self] in
                    self?.receive(text, final: final, failed: failed, epoch: epoch)
                }
            }
            recognition = recognizer.recognitionTask(with: request, resultHandler: receive)
            engine.prepare()
            try engine.start()
            phase = .recording
            // SFSpeechRecognizer handles short dictation. Stop capture before its one-minute limit.
            limit = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(55)) }
                catch { return }
                guard let self, self.generation == epoch else { return }
                self.stop()
            }
        } catch { fail("native.error.generic") }
    }

    /// Stop the microphone immediately, then allow a bounded final transcription before review.
    func stop() {
        guard phase == .recording else { return }
        stopInput()
        phase = .finishing
        let epoch = generation
        limit = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            guard let self, self.generation == epoch, self.phase == .finishing else { return }
            self.finishReview()
        }
    }

    func interrupted() {
        guard phase == .recording || phase == .finishing else { return }
        finishReview()
    }

    func configurationChanged(_ notification: Notification) {
        guard let engine, let changed = notification.object as? AVAudioEngine, changed === engine else { return }
        interrupted()
    }

    /// Call on dismissal, background, or account/chat change. No partial text leaves this session.
    func cancel() {
        generation += 1
        releaseAudio()
        phase = .idle
        transcript = ""
        problem = nil
        canOpenSettings = false
    }

    private func receive(_ text: String?, final: Bool, failed: Bool, epoch: Int) {
        guard generation == epoch, phase == .recording || phase == .finishing else { return }
        if let text { transcript = text }
        if final || failed {
            finishReview()
        }
    }

    private func fail(_ message: LocalizedStringResource) {
        generation += 1
        releaseAudio()
        phase = .review
        problem = message
    }

    private func finishReview() {
        generation += 1
        releaseAudio()
        phase = .review
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problem = "native.error.generic" }
    }

    private func stopInput() {
        limit?.cancel(); limit = nil
        engine?.stop()
        if hasTap { engine?.inputNode.removeTap(onBus: 0); hasTap = false }
        audio?.finish(); audio = nil
        engine = nil
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
    }

    private func releaseAudio() {
        stopInput()
        recognition?.cancel(); recognition = nil
        recognizer = nil
    }

    nonisolated private static func speechPermission() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status) }
        }
    }

    nonisolated private static func installTap(_ input: AVAudioInputNode, format: AVAudioFormat, audio: DictationAudioSink) {
        // A tap executes on the real-time audio thread, never on MainActor.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in audio.append(buffer) }
    }
}

/// The sole cross-thread reference. The lock serializes append/endAudio and releases the request
/// before a late audio callback can append after cancellation. No UI state crosses this boundary.
nonisolated private final class DictationAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        request?.append(buffer)
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        request?.endAudio()
        request = nil
    }
}
