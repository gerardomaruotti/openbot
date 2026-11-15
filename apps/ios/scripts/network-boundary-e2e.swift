import Foundation

@main
struct NativeNetworkBoundaryE2E {
    @MainActor
    static func main() async {
        var stage = "origin"
        do {
            if CommandLine.arguments.contains("--release-policy") {
                guard AccountOrigin(URL(string: "http://127.0.0.1:3100")!) == nil,
                      AccountOrigin(URL(string: "https://name:password@example.com")!) == nil,
                      AccountOrigin(URL(string: "https://example.com")!) != nil else { throw ConnectionProblem.protocolError }
                print("{\"releaseHTTPSOnly\":true}")
                return
            }
            guard CommandLine.arguments.count == 3,
                  let origin = URL(string: CommandLine.arguments[1]),
                  let other = URL(string: CommandLine.arguments[2]) else { throw ConnectionProblem.protocolError }
            let client = try AccountHTTPClient(apiURL: origin)
            defer { client.close() }
            let headers = ["authorization": "Bearer native-synthetic-boundary-fixture"]
            stage = "same-origin-redirect"
            let (data, response) = try await client.perform(url: origin.appendingPathComponent("same"), method: "GET", headers: headers, body: nil)
            guard response.statusCode == 200, String(decoding: data, as: UTF8.self) == "same-origin" else { throw ConnectionProblem.protocolError }
            stage = "cross-origin-redirect"
            let (_, redirected) = try await client.perform(url: origin.appendingPathComponent("cross"), method: "GET", headers: headers, body: nil)
            guard redirected.statusCode == 302 else { throw ConnectionProblem.protocolError }
            do {
                stage = "direct-other-origin"
                _ = try await client.perform(url: other.appendingPathComponent("direct"), method: "GET", headers: headers, body: nil)
                throw ConnectionProblem.protocolError
            } catch ConnectionProblem.invalidLink { }
            do {
                stage = "response-size"
                _ = try await client.perform(url: origin.appendingPathComponent("large"), method: "GET", headers: headers, body: nil)
                throw ConnectionProblem.network
            } catch ConnectionProblem.protocolError { }
            print("{\"sameOriginRedirect\":true,\"crossOriginRedirectBlocked\":true,\"directOtherOriginBlocked\":true,\"oversizedResponseBlocked\":true}")
        } catch {
            let code = (error as NSError).code
            print("{\"passed\":false,\"stage\":\"\(stage)\",\"code\":\(code)}")
            exit(1)
        }
    }
}
