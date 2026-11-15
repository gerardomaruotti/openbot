import SwiftUI
import WebKit
import Observation

@Observable
@MainActor
final class HostTransport: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
    @ObservationIgnored private(set) var webView: WKWebView
    private(set) var identity = UUID()
    var receive: ((WireValue) -> Void)?
    var pin: ((String, String) throws -> Void)?
    private let pageURL: URL?
    @ObservationIgnored private var account: AccountHTTPClient?
    @ObservationIgnored private var didLoad = false
    @ObservationIgnored private var loading: CheckedContinuation<Void, Error>?

    override init() {
        webView = Self.makeWebView()
        pageURL = Bundle.main.url(forResource: "team-peer", withExtension: "html", subdirectory: "Transport")
        super.init()
        bindWebView()
    }

    private static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
    }

    private func bindWebView() {
        webView.configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "openbotNative")
        webView.navigationDelegate = self
        webView.isUserInteractionEnabled = false
        webView.alpha = 0.01
        webView.isInspectable = false
    }

    /// End the old account's network access and JavaScript lifetime without a remote reply.
    func reset() {
        identity = UUID()
        account?.close()
        account = nil
        loadFailed()
        let previous = webView
        previous.configuration.userContentController.removeScriptMessageHandler(forName: "openbotNative", contentWorld: .page)
        previous.navigationDelegate = nil
        previous.stopLoading()
        previous.removeFromSuperview()
        // This empty local document releases any old RTC peer while SwiftUI replaces
        // the view. It has no script handler, origin client or navigation delegate.
        previous.loadHTMLString("", baseURL: nil)
        webView = Self.makeWebView()
        bindWebView()
    }

    func useAccount(_ address: String) throws {
        guard let url = URL(string: address) else { throw ConnectionProblem.invalidLink }
        if account?.origin.allows(url) == true { return }
        account?.close()
        account = try AccountHTTPClient(apiURL: url)
    }

    func execute(_ command: [String: WireValue]) async throws -> WireValue {
        let epoch = identity
        try await load()
        try Task.checkCancellation()
        guard identity == epoch else { throw ConnectionProblem.auth }
        let data = try JSONEncoder().encode(command)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConnectionProblem.protocolError }
        let result = try await webView.callAsyncJavaScript("return JSON.stringify(await window.openbotNative.execute(command));", arguments: ["command": value], contentWorld: .page)
        guard identity == epoch else { throw ConnectionProblem.auth }
        guard let string = result as? String, let reply = string.data(using: .utf8) else { throw ConnectionProblem.protocolError }
        let envelope = try JSONDecoder().decode(WireValue.self, from: reply)
        guard envelope["ok"]?.bool == true else { throw ConnectionProblem(rawValue: envelope["code"]?.string ?? "") ?? .network }
        return envelope["value"] ?? .null
    }

    private func load() async throws {
        if didLoad { return }
        guard let pageURL, loading == nil else { throw ConnectionProblem.network }
        try await withCheckedThrowingContinuation { continuation in
            loading = continuation
            webView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        didLoad = true
        loading?.resume()
        loading = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView { loadFailed() }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView { loadFailed() }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        loadFailed()
        receive?(.object(["type": .string("reset")]))
    }

    private func loadFailed() {
        didLoad = false
        loading?.resume(throwing: ConnectionProblem.network)
        loading = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        webView === self.webView && navigationAction.request.url == pageURL && navigationAction.targetFrame?.isMainFrame == true ? .allow : .cancel
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard message.webView === webView, message.frameInfo.isMainFrame, message.frameInfo.request.url == pageURL,
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return (nil, "Rejected bridge request") }
        do {
            switch type {
            case "fetch":
                guard let account, let address = body["url"] as? String, let url = URL(string: address),
                      let method = body["method"] as? String, let headers = body["headers"] as? [String: String] else { throw ConnectionProblem.protocolError }
                let (data, response) = try await account.perform(url: url, method: method, headers: headers, body: body["body"] as? String)
                var responseHeaders: [String: String] = [:]
                for (key, value) in response.allHeaderFields {
                    if let key = key as? String, let value = value as? String { responseHeaders[key.lowercased()] = value }
                }
                return (["status": response.statusCode, "headers": responseHeaders, "body": String(decoding: data, as: UTF8.self)], nil)
            case "event":
                guard let value = body["event"] else { throw ConnectionProblem.protocolError }
                let data = try JSONSerialization.data(withJSONObject: value)
                receive?(try JSONDecoder().decode(WireValue.self, from: data))
                return (true, nil)
            case "pin":
                guard let hostID = body["hostId"] as? String, let key = body["publicKey"] as? String,
                      hostID.count <= 128, key.count <= 4096, let pin else { throw ConnectionProblem.protocolError }
                try pin(hostID, key)
                return (true, nil)
            default: throw ConnectionProblem.protocolError
            }
        } catch { return (nil, "The connection request failed") }
    }
}

struct HostTransportView: View {
    let transport: HostTransport

    var body: some View {
        HostTransportWebView(webView: transport.webView).id(transport.identity)
    }
}

private struct HostTransportWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
}
