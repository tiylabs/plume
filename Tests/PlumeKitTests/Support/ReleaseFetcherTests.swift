import Foundation
import PlumeKit

/// Answers every request with fixed bytes or a fixed error, and remembers the request it was given.
private final class StubFetcher: HTTPFetching, @unchecked Sendable {
    var data: Data?
    var error: (any Error)?
    private(set) var requests: [URLRequest] = []

    init(json: String) { data = Data(json.utf8) }
    init(data: Data?, error: (any Error)? = nil) { self.data = data; self.error = error }

    func fetch(_ request: URLRequest, completion: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        requests.append(request)
        completion(data, error)
    }
}

private final class StatusBox: @unchecked Sendable {
    var value: ReleaseCheck.Status?
}

/// The stub answers synchronously, so the completion has run by the time `fetchStatus` returns. A nil
/// here would mean it never ran, which is a failure of its own and must not look like `.unknown`.
private func status(_ stub: StubFetcher, running: String = "0.7.2") -> ReleaseCheck.Status? {
    let box = StatusBox()
    ReleaseFetcher.fetchStatus(using: stub, runningVersion: running) { box.value = $0 }
    Check.expect(box.value != nil, "fetchStatus never called its completion")
    return box.value
}

func runReleaseFetcherTests() {
    Check.suite("ReleaseFetcher") {

        Check.test("a newer tag on GitHub is reported as an available update") {
            let result = status(StubFetcher(json: #"{"tag_name": "v0.9.0", "name": "x"}"#))
            Check.equal(result, .behind("v0.9.0"))
            Check.equal(result, ReleaseCheck.status(current: "0.7.2", latest: "v0.9.0"))
        }

        Check.test("the same tag is reported as up to date") {
            let result = status(StubFetcher(json: #"{"tag_name": "v0.7.2"}"#))
            Check.equal(result, .current)
        }

        Check.test("a body that is not the release JSON is unknown, not an error") {
            for body in ["<html>Sign in to Wi-Fi</html>", "", "{}", #"{"tag_name": 7}"#, "[1,2]"] {
                Check.equal(status(StubFetcher(json: body)), .unknown, "body: \(body)")
            }
        }

        Check.test("a network failure is unknown even when some bytes arrived") {
            struct Offline: Error {}
            Check.equal(status(StubFetcher(data: nil, error: Offline())), .unknown)
            Check.equal(
                status(StubFetcher(data: Data(#"{"tag_name": "v9.9.9"}"#.utf8), error: Offline())), .unknown,
                "an error wins over a body: half a response is not an answer"
            )
        }

        Check.test("the request names the version and nothing about the machine") {
            let stub = StubFetcher(json: #"{"tag_name": "v0.7.2"}"#)
            _ = status(stub, running: "1.2.3")
            let request = stub.requests.first
            Check.equal(request?.url, ReleaseFetcher.releasesAPI)
            Check.equal(request?.value(forHTTPHeaderField: "User-Agent"), "Plume/1.2.3")
            Check.equal(request?.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            Check.equal(request?.timeoutInterval, 10)
            Check.equal(request?.httpMethod, "GET")
            Check.equal(request?.allHTTPHeaderFields?.count, 2, "no other header is sent")
            Check.equal(stub.requests.count, 1)
        }

        Check.test("an unparseable tag is unknown rather than a false 'update available'") {
            Check.equal(status(StubFetcher(json: #"{"tag_name": "nightly"}"#)), .unknown)
        }
    }
}
