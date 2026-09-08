import Foundation

/// Immutable URLProtocol fixture; each request describes its own redirect.
/// URLProtocol's Foundation callbacks require this Sendable conformance.
final class CredentialRedirectFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.host == "capture.example" {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var redirected = request
        redirected.url = URL(string: "http://capture.example/capture")!
        let response = HTTPURLResponse(
            url: url, statusCode: Int(url.lastPathComponent)!, httpVersion: nil,
            headerFields: ["Location": redirected.url!.absoluteString])!
        client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
    }

    override func stopLoading() {}
}
