import Foundation

/// Sends one HTTP request and reports the body or the error. The seam between the one network call
/// Plume makes and the network: the app uses `URLSessionFetcher`, a test hands back canned bytes.
///
/// Deliberately smaller than `URLSession`: no response object, no status code. Plume's only request
/// treats every failure the same way (`ReleaseCheck.Status.unknown`), so there is nothing a status
/// code would be used for, and a narrower protocol is a smaller thing to fake.
public protocol HTTPFetching: Sendable {
    func fetch(_ request: URLRequest, completion: @escaping @Sendable (Data?, (any Error)?) -> Void)
}

/// `URLSession.shared`.
public struct URLSessionFetcher: HTTPFetching {

    public init() {}

    public func fetch(_ request: URLRequest, completion: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        URLSession.shared.dataTask(with: request) { data, _, error in
            completion(data, error)
        }.resume()
    }
}
