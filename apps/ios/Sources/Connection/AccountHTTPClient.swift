import Foundation

struct AccountOrigin: Equatable, Sendable {
    let scheme: String
    let host: String
    let port: Int

    nonisolated init?(_ url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(), !host.isEmpty,
              scheme == "https" || Self.allowsDevelopmentHTTP(scheme: scheme, host: host) else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = parts.port ?? (scheme == "https" ? 443 : 80)
    }

    nonisolated func allows(_ url: URL) -> Bool { AccountOrigin(url) == self }

    nonisolated private static func allowsDevelopmentHTTP(scheme: String, host: String) -> Bool {
        #if DEBUG
        guard scheme == "http" else { return false }
        if host == "localhost" || host == "127.0.0.1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { Int($0) }
        guard parts.count == 4, octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }),
              zip(parts, octets).allSatisfy({ String($0.1) == $0.0 }) else { return false }
        return octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 192 && octets[1] == 168)
        #else
        return false
        #endif
    }
}

final class AccountRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated let origin: AccountOrigin
    init(origin: AccountOrigin) { self.origin = origin }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url.map(origin.allows) == true else { completionHandler(nil); return }
        var allowed = request
        if let authorization = task.originalRequest?.value(forHTTPHeaderField: "Authorization") {
            allowed.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        completionHandler(allowed)
    }
}

/// Account credentials cannot follow a redirect to another scheme, host or port.
final class AccountHTTPClient {
    let origin: AccountOrigin
    private let session: URLSession

    init(apiURL: URL) throws {
        guard let origin = AccountOrigin(apiURL), apiURL.query == nil, apiURL.fragment == nil,
              apiURL.path.isEmpty || apiURL.path == "/" else { throw ConnectionProblem.invalidLink }
        self.origin = origin
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 35
        configuration.timeoutIntervalForResource = 45
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration, delegate: AccountRedirectGuard(origin: origin), delegateQueue: nil)
    }

    func perform(url: URL, method: String, headers: [String: String], body: String?) async throws -> (Data, HTTPURLResponse) {
        guard origin.allows(url), ["GET", "POST", "DELETE"].contains(method) else { throw ConnectionProblem.invalidLink }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body.map { Data($0.utf8) }
        for (name, value) in headers {
            guard ["authorization", "content-type", "idempotency-key"].contains(name.lowercased()),
                  value.utf8.count <= 8192, value.rangeOfCharacter(from: .controlCharacters) == nil else { throw ConnectionProblem.protocolError }
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw ConnectionProblem.network }
        guard response.expectedContentLength <= 2_097_152 else { throw ConnectionProblem.protocolError }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2_097_152 else { throw ConnectionProblem.protocolError }
            data.append(byte)
        }
        return (data, response)
    }

    func close() { session.invalidateAndCancel() }
}
