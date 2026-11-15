import SwiftUI
import UIKit

/// The store owns the session. This screen owns only text that has not been sent.
struct BrowserSessionScreen: View {
    let session: NativeBrowserSession
    let connection: AgentConnection
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var ownerIntent: NativeBrowserIntent?
    @State private var typedText = ""
    @State private var secret = ""
    @State private var textIntent: NativeBrowserIntent?
    @State private var secretIntent: NativeBrowserIntent?
    @State private var confirmsCompletion = false
    @State private var confirmsCancellation = false
    @State private var completionIntent: NativeBrowserIntent?
    @State private var cancellationIntent: NativeBrowserIntent?

    init(session: NativeBrowserSession, connection: AgentConnection) {
        self.session = session
        self.connection = connection
        _ownerIntent = State(initialValue: session.intent)
    }

    private var renderedIntent: NativeBrowserIntent? {
        guard let intent = session.intent, intent.sessionID == ownerIntent?.sessionID else { return nil }
        return intent
    }

    var body: some View {
        // These values belong to this render. No action reads a replacement request inside its Task.
        let intent = renderedIntent
        let completing = completionIntent
        let cancelling = cancellationIntent
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    BrowserRequestHeader(request: intent?.request, phase: intent == nil ? .ended : session.phase)
                    if let intent {
                        if let problem = session.problem {
                            Text(problem).foregroundStyle(.red).accessibilityAddTraits(.updatesFrequently)
                        }
                        if let frame = session.frame {
                            BrowserLiveCanvas(
                                frame: frame, enabled: session.canInteract && connection.canSend,
                                click: { x, y, sequence in
                                    Task { await session.click(x: x, y: y, sequence: sequence,
                                                               intent: intent, connection: connection) }
                                },
                                scroll: { x, y, dx, dy, sequence in
                                    Task { await session.scroll(x: x, y: y, deltaX: dx, deltaY: dy,
                                                                sequence: sequence, intent: intent, connection: connection) }
                                },
                                displayed: { viewID, sequence in
                                    session.frameDisplayed(viewID: viewID, sequence: sequence,
                                                           intent: intent, connection: connection)
                                }
                            )
                            .frame(minHeight: 260, idealHeight: 340, maxHeight: 420)
                            .background(.quaternary, in: .rect(cornerRadius: 16))
                            .clipShape(.rect(cornerRadius: 16))
                            .privacySensitive()
                            BrowserInputControls(
                                text: textBinding(intent: intent), enabled: session.canInteract && connection.canSend,
                                send: { sendText(intent: intent) },
                                key: { key in Task { await session.key(key, intent: intent, connection: connection) } },
                                scroll: { direction in
                                    Task {
                                        await session.scroll(deltaY: Double(frame.height) * direction * 0.7,
                                                             sequence: frame.sequence, intent: intent, connection: connection)
                                    }
                                }
                            )
                        } else if session.phase == .checking || session.phase == .connecting {
                            ProgressView().frame(maxWidth: .infinity).padding()
                        }
                        if session.canSubmitSecret {
                            BrowserSecretInput(
                                secret: secretBinding(intent: intent), origin: intent.request.wire["secret"]?["origin"]?.string,
                                password: intent.request.method == "password", enabled: connection.canSend,
                                allowsBrowser: session.supportsView,
                                submit: { submitSecret(intent: intent) },
                                takeOver: {
                                    guard session.accepts(intent, connection: connection) else { return }
                                    secret = ""
                                    secretIntent = nil
                                    Task { await session.takeOverSecret(intent: intent, connection: connection) }
                                }
                            )
                        }
                        BrowserSessionActions(
                            phase: session.phase,
                            enabled: connection.canSend && session.canRespond,
                            allowsCompletion: !session.needsSecret,
                            responding: session.responding,
                            resume: { Task { await session.resume(intent: intent, connection: connection, userInitiated: true) } },
                            complete: {
                                guard session.accepts(intent, connection: connection) else { return }
                                completionIntent = intent
                                confirmsCompletion = true
                            },
                            cancel: {
                                guard session.accepts(intent, connection: connection) else { return }
                                cancellationIntent = intent
                                confirmsCancellation = true
                            }
                        )
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("native.browser.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("native.browser.close") {
                        clearInput()
                        if let ownerIntent { session.close(intent: ownerIntent) }
                        dismiss()
                    }
                }
            }
            .confirmationDialog("native.browser.completeTitle", isPresented: $confirmsCompletion, titleVisibility: .visible) {
                Button("native.browser.complete") {
                    guard let confirmed = completing, completionIntent == confirmed,
                          session.accepts(confirmed, connection: connection) else { return }
                    clearInput()
                    Task { await session.respond("complete", intent: confirmed, connection: connection) }
                }
                Button("native.browser.keepWorking", role: .cancel) { completionIntent = nil }
            } message: { Text("native.browser.completeBody") }
            .confirmationDialog("native.browser.cancelTitle", isPresented: $confirmsCancellation, titleVisibility: .visible) {
                Button("native.browser.cancelRequest", role: .destructive) {
                    guard let confirmed = cancelling, cancellationIntent == confirmed,
                          session.accepts(confirmed, connection: connection) else { return }
                    clearInput()
                    Task { await session.respond("cancel", intent: confirmed, connection: connection) }
                }
                Button("native.browser.keepWorking", role: .cancel) { cancellationIntent = nil }
            }
        }
        .task { if let intent { await session.resume(intent: intent, connection: connection, userInitiated: true) } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                if let intent { Task { await session.resume(intent: intent, connection: connection) } }
            } else {
                clearInput()
                if let intent { session.pause(intent: intent) }
            }
        }
        .onChange(of: connection.phase) { _, phase in
            if phase != .online {
                clearInput()
                if let intent { session.pause(intent: intent) }
            }
        }
        .onChange(of: session.phase) { _, phase in
            clearDialogs()
            if phase != .live && phase != .secret { clearText() }
        }
        .onChange(of: session.intent) { _, new in
            clearInput()
            if new?.sessionID != ownerIntent?.sessionID { dismiss() }
        }
        .onChange(of: session.request?.wire) { old, new in
            clearInput()
            if new != nil && old != new && connection.canSend, let replacement = renderedIntent {
                // Open only the host's replacement request. Input is never replayed.
                Task { await session.resume(intent: replacement, connection: connection) }
            }
        }
        .onDisappear {
            clearInput()
            if let ownerIntent { session.close(intent: ownerIntent) }
        }
    }

    private func sendText(intent: NativeBrowserIntent) {
        guard textIntent == intent, session.accepts(intent, connection: connection), session.canInteract else { return }
        let value = typedText
        typedText = ""
        textIntent = nil
        Task { await session.typeText(value, intent: intent, connection: connection) }
    }

    private func submitSecret(intent: NativeBrowserIntent) {
        guard secretIntent == intent, session.accepts(intent, connection: connection), session.canSubmitSecret else { return }
        let value = secret
        secret = ""
        secretIntent = nil
        Task { await session.submitSecret(value, intent: intent, connection: connection) }
    }

    private func textBinding(intent: NativeBrowserIntent) -> Binding<String> {
        Binding(get: { textIntent == intent ? typedText : "" }, set: { value in
            guard session.accepts(intent, connection: connection) else { return }
            textIntent = intent
            typedText = value
        })
    }

    private func secretBinding(intent: NativeBrowserIntent) -> Binding<String> {
        Binding(get: { secretIntent == intent ? secret : "" }, set: { value in
            guard session.accepts(intent, connection: connection) else { return }
            secretIntent = intent
            secret = value
        })
    }

    private func clearText() { typedText = ""; secret = ""; textIntent = nil; secretIntent = nil }
    private func clearDialogs() {
        confirmsCompletion = false; confirmsCancellation = false
        completionIntent = nil; cancellationIntent = nil
    }
    private func clearInput() { clearText(); clearDialogs() }
}

private struct BrowserRequestHeader: View {
    let request: AgentBrowserHandoff?
    let phase: NativeBrowserSession.Phase

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let site = request?.site {
                Label(site, systemImage: "globe").font(.headline).textSelection(.enabled)
            }
            if phase == .secret { Text("native.browser.secretBody").foregroundStyle(.secondary) }
            if phase == .resolved { Text("native.browser.resolved").foregroundStyle(.secondary) }
        }
    }
}

private struct BrowserInputControls: View {
    @Binding var text: String
    let enabled: Bool
    let send: () -> Void
    let key: (String) -> Void
    let scroll: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { scroll(-1) } label: { Label("native.browser.scrollUp", systemImage: "arrow.up") }
                Spacer()
                Button { scroll(1) } label: { Label("native.browser.scrollDown", systemImage: "arrow.down") }
            }
            HStack(spacing: 16) {
                Button("native.browser.tab") { key("Tab") }
                Button("native.browser.return") { key("Enter") }
                Button("native.browser.backspace") { key("Backspace") }
            }
            HStack(alignment: .bottom) {
                TextField("native.browser.text", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                    .onSubmit(send)
                Button("native.browser.sendText", action: send)
                    .disabled(text.isEmpty || text.utf16.count > 4_096)
            }
            if text.utf16.count > 4_096 { Text("native.browser.textTooLong").font(.footnote).foregroundStyle(.red) }
        }
        .buttonStyle(.bordered)
        .disabled(!enabled)
    }
}

private struct BrowserSecretInput: View {
    @Binding var secret: String
    let origin: String?
    let password: Bool
    let enabled: Bool
    let allowsBrowser: Bool
    let submit: () -> Void
    let takeOver: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("native.browser.secureTitle").font(.headline)
            if let origin { Text(origin).font(.callout).textSelection(.enabled) }
            Text("native.browser.secretPrivacy").font(.footnote).foregroundStyle(.secondary)
            SecureField(text: $secret) {
                Text(password ? LocalizedStringResource("native.browser.password") : LocalizedStringResource("native.browser.code"))
            }
                .textContentType(.oneTimeCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .privacySensitive()
                .onSubmit { if !secret.isEmpty && secret.utf16.count <= 4_096 { submit() } }
            Button("native.browser.submitSecret", action: submit)
                .buttonStyle(.borderedProminent)
                .disabled(secret.isEmpty || secret.utf16.count > 4_096)
            if allowsBrowser {
                Button("native.browser.openInstead", action: takeOver).buttonStyle(.bordered)
            }
        }
        .disabled(!enabled)
    }
}

private struct BrowserSessionActions: View {
    let phase: NativeBrowserSession.Phase
    let enabled: Bool
    let allowsCompletion: Bool
    let responding: Bool
    let resume: () -> Void
    let complete: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if phase == .paused || phase == .ended || phase == .unsupported {
                Button("native.browser.resume", action: resume).buttonStyle(.bordered)
            }
            if phase != .resolved {
                if allowsCompletion {
                    Button("native.browser.complete", action: complete).buttonStyle(.borderedProminent)
                }
                Button("native.browser.cancelRequest", role: .destructive, action: cancel).buttonStyle(.bordered)
            }
            if responding { ProgressView() }
        }
        .disabled(!enabled)
    }
}

/// Pinch and one-finger pan inspect the image locally. A tap clicks the page; a two-finger
/// pan scrolls the host page. Coordinates always use the displayed image, not the letterbox.
private struct BrowserLiveCanvas: UIViewRepresentable {
    let frame: NativeBrowserFrame
    let enabled: Bool
    let click: (Double, Double, Int) -> Void
    let scroll: (Double, Double, Double, Double, Int) -> Void
    let displayed: (String, Int) -> Void

    func makeUIView(context: Context) -> BrowserCanvasView { BrowserCanvasView() }

    static func dismantleUIView(_ view: BrowserCanvasView, coordinator: ()) { view.clear() }

    func updateUIView(_ view: BrowserCanvasView, context: Context) {
        view.click = click
        view.scrollPage = scroll
        view.displayed = displayed
        view.acceptsInput = enabled
        view.show(frame)
    }
}

private final class BrowserCanvasView: UIView, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private var shown: NativeBrowserFrame?
    private var fitSize = CGSize.zero
    var acceptsInput = false
    var click: ((Double, Double, Int) -> Void)?
    var scrollPage: ((Double, Double, Double, Double, Int) -> Void)?
    var displayed: ((String, Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.panGestureRecognizer.maximumNumberOfTouches = 1
        addSubview(scrollView)
        scrollView.addSubview(imageView)
        imageView.isUserInteractionEnabled = true
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = String(localized: "native.browser.pageImage")
        imageView.accessibilityHint = String(localized: "native.browser.pageAccessibility")
        imageView.accessibilityTraits = .image
        imageView.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "native.browser.scrollUp")) { [weak self] _ in self?.accessibleScroll(-1) ?? false },
            UIAccessibilityCustomAction(name: String(localized: "native.browser.scrollDown")) { [weak self] _ in self?.accessibleScroll(1) ?? false }
        ]
        imageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap(_:))))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(remoteScroll(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        imageView.addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        guard let shown, bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(bounds.width / CGFloat(shown.width), bounds.height / CGFloat(shown.height))
        let next = CGSize(width: CGFloat(shown.width) * scale, height: CGFloat(shown.height) * scale)
        if next != fitSize {
            fitSize = next
            scrollView.setZoomScale(1, animated: false)
            imageView.frame = CGRect(origin: .zero, size: next)
            scrollView.contentSize = next
        }
        centerImage()
    }

    func show(_ frame: NativeBrowserFrame) {
        guard shown?.viewID != frame.viewID || shown?.sequence != frame.sequence else { return }
        shown = frame
        let viewID = frame.viewID
        let sequence = frame.sequence
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                guard let self, self.shown?.viewID == viewID, self.shown?.sequence == sequence else { return }
                self.displayed?(viewID, sequence)
            }
        }
        imageView.image = frame.image
        setNeedsLayout()
        layoutIfNeeded()
        CATransaction.commit()
    }

    func clear() {
        acceptsInput = false
        shown = nil
        imageView.image = nil
        click = nil
        scrollPage = nil
        displayed = nil
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    private func centerImage() {
        scrollView.contentInset = UIEdgeInsets(
            top: max(0, (bounds.height - imageView.frame.height) / 2), left: 0,
            bottom: 0, right: 0
        )
        scrollView.contentInset.left = max(0, (bounds.width - imageView.frame.width) / 2)
    }

    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        guard acceptsInput, let shown else { return }
        let point = gesture.location(in: imageView)
        guard imageView.bounds.contains(point) else { return }
        click?(Double(point.x / imageView.bounds.width), Double(point.y / imageView.bounds.height), shown.sequence)
    }

    @objc private func remoteScroll(_ gesture: UIPanGestureRecognizer) {
        guard acceptsInput, gesture.state == .ended, let shown else { return }
        let point = gesture.location(in: imageView)
        let delta = gesture.translation(in: imageView)
        let width = max(1, imageView.bounds.width), height = max(1, imageView.bounds.height)
        scrollPage?(Double(max(0, min(1, point.x / width))), Double(max(0, min(1, point.y / height))),
                    -Double(delta.x / width) * Double(shown.width),
                    -Double(delta.y / height) * Double(shown.height), shown.sequence)
    }

    private func accessibleScroll(_ direction: Double) -> Bool {
        guard acceptsInput, let shown else { return false }
        scrollPage?(0.5, 0.5, 0, Double(shown.height) * direction * 0.7, shown.sequence)
        return true
    }
}
