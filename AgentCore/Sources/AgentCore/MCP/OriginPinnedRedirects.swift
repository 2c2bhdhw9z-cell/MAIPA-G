import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Which redirects a credential-bearing connector request may follow: only to the same origin
/// (scheme, host and port), or from HTTP up to HTTPS on the same host. Never to another host,
/// never from HTTPS back to HTTP, and never to an address with a username or password in it.
public enum CredentialRedirectPolicy {
    public static func allows(from original: URL?, to target: URL?) -> Bool {
        guard let original, let target,
              let fromScheme = original.scheme?.lowercased(), let toScheme = target.scheme?.lowercased(),
              let fromHost = original.host?.lowercased(), let toHost = target.host?.lowercased()
        else { return false }
        guard target.user == nil, target.password == nil, fromHost == toHost else { return false }
        guard toScheme == "https" || (toScheme == "http" && fromScheme == "http") else { return false }
        if fromScheme == toScheme { return effectivePort(original) == effectivePort(target) }
        // http → https upgrade on the same host only.
        return fromScheme == "http" && toScheme == "https" && (target.port == nil || target.port == 443)
    }

    static func effectivePort(_ url: URL) -> Int {
        if let port = url.port { return port }
        return url.scheme?.lowercased() == "http" ? 80 : 443
    }
}

/// The official MCP SDK's HTTP transport builds its own URLSession without a redirect delegate,
/// so a server could redirect a request carrying MAIPA-G's bearer token to another host. This
/// URL protocol sits inside that session: it performs each request itself, follows only
/// redirects `CredentialRedirectPolicy` allows, and hands any other redirect back unfollowed,
/// so the SDK sees the 3xx answer and stops.
#if canImport(FoundationNetworking)
/// Remote connector sessions only run on the phone. Linux's Foundation can't host a URL protocol
/// that runs its own session (it deadlocks on its single networking queue), so on Linux this
/// leaves the configuration as it is.
public enum OriginPinnedRedirectProtocol {
    public static func configuration(base: URLSessionConfiguration = .ephemeral) -> URLSessionConfiguration { base }
}
#else
public final class OriginPinnedRedirectProtocol: URLProtocol {
    private static let handledKey = "MAIPAGOriginPinnedRedirect"
    private let lock = NSLock()
    private var forwarder: RedirectCheckingForwarder?

    /// A session configuration for the SDK transport with this protocol installed first.
    public static func configuration(base: URLSessionConfiguration = .ephemeral) -> URLSessionConfiguration {
        base.protocolClasses = [OriginPinnedRedirectProtocol.self] + (base.protocolClasses ?? [])
        return base
    }

    public override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
        return URLProtocol.property(forKey: handledKey, in: request) == nil
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        var forwarded = request
        if let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest {
            URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)
            forwarded = mutable as URLRequest
        }
        let forwarder = RedirectCheckingForwarder(owner: self, originalURL: request.url)
        lock.lock()
        self.forwarder = forwarder
        lock.unlock()
        forwarder.start(forwarded, timeout: request.timeoutInterval)
    }

    public override func stopLoading() {
        lock.lock()
        let forwarder = self.forwarder
        self.forwarder = nil
        lock.unlock()
        forwarder?.stop()
    }
}

/// Performs one request for `OriginPinnedRedirectProtocol` and relays its answer.
private final class RedirectCheckingForwarder: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var owner: OriginPinnedRedirectProtocol?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private let originalURL: URL?
    private var refusedRedirect: URL?
    private var deliveredHead = false

    init(owner: OriginPinnedRedirectProtocol, originalURL: URL?) {
        self.owner = owner
        self.originalURL = originalURL
    }

    func start(_ request: URLRequest, timeout: TimeInterval) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout > 0 ? timeout : 60
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        lock.lock()
        self.session = session
        self.task = task
        lock.unlock()
        task.resume()
    }

    func stop() {
        lock.lock()
        let task = self.task, session = self.session
        self.task = nil
        self.session = nil
        owner = nil
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
    }

    private func currentOwner() -> OriginPinnedRedirectProtocol? {
        lock.lock()
        defer { lock.unlock() }
        return owner
    }

    // Signatures match HTTP.swift's NoRedirectDelegate. The "did receive response" method is
    // deliberately not used (its completion handler differs between SDKs, and a method that
    // doesn't match is silently never called); the response head goes with the first data.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if CredentialRedirectPolicy.allows(from: task.originalRequest?.url ?? originalURL, to: request.url) {
            completionHandler(request)
        } else {
            // Not followed, and nothing is sent to the new place: the request fails instead.
            lock.lock()
            refusedRedirect = request.url
            lock.unlock()
            completionHandler(nil)
        }
    }

    private func refused() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return refusedRedirect
    }

    private func deliverHead(of task: URLSessionTask, to owner: OriginPinnedRedirectProtocol) {
        lock.lock()
        let already = deliveredHead
        deliveredHead = true
        lock.unlock()
        guard !already, let response = task.response else { return }
        owner.client?.urlProtocol(owner, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard refused() == nil, let owner = currentOwner() else { return }
        deliverHead(of: dataTask, to: owner)
        owner.client?.urlProtocol(owner, didLoad: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let owner = currentOwner() {
            if let target = refused() {
                owner.client?.urlProtocol(owner, didFailWithError: URLError(.cannotLoadFromNetwork, userInfo: [
                    NSLocalizedDescriptionKey: "The connector tried to send this request to \(target.host ?? "another address"). MAIPA-G stopped it so your sign-in isn't sent anywhere else.",
                ]))
            } else if let error {
                owner.client?.urlProtocol(owner, didFailWithError: error)
            } else {
                deliverHead(of: task, to: owner)
                owner.client?.urlProtocolDidFinishLoading(owner)
            }
        }
        lock.lock()
        owner = nil
        self.session = nil
        self.task = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
    }
}
#endif
