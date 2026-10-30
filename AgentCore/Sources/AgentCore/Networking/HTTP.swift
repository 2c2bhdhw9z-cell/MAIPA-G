import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One HTTP request. Plain data, so it can be built, logged and tested without URLSession.
public struct HTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    /// OAuth and other credential-bearing calls can reject redirects before a body or secret is
    /// replayed to a different address.
    public var followsRedirects: Bool
    /// Longest silence allowed between two packets. AI replies can pause while the model thinks, and
    /// OpenRouter sends a keep-alive comment every few seconds, so two minutes is generous.
    public var idleTimeout: TimeInterval

    public init(
        method: String = "GET",
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        idleTimeout: TimeInterval = 60,
        followsRedirects: Bool = true
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.idleTimeout = idleTimeout
        self.followsRedirects = followsRedirects
    }

    public static func json<Body: Encodable>(
        _ method: String,
        _ url: URL,
        body: Body,
        headers: [String: String] = [:],
        idleTimeout: TimeInterval = 60
    ) throws -> HTTPRequest {
        var headers = headers
        headers["Content-Type"] = "application/json"
        return HTTPRequest(
            method: method,
            url: url,
            headers: headers,
            body: try JSONCoding.encoder().encode(body),
            idleTimeout: idleTimeout
        )
    }
}

/// A complete HTTP response. Header names are lower-cased.
public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public var finalURL: URL?

    public init(status: Int, headers: [String: String] = [:], body: Data = Data(), finalURL: URL? = nil) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
        self.finalURL = finalURL
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
    public var isSuccess: Bool { (200..<300).contains(status) }
    public var text: String { String(decoding: body, as: UTF8.self) }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        do {
            return try JSONCoding.decoder().decode(type, from: body)
        } catch {
            throw HTTPError.undecodable(status: status, type: String(describing: type), detail: "\(error)", body: text)
        }
    }
}

/// The head of a streaming response, and its body as it arrives.
public struct HTTPStreamResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: AsyncThrowingStream<Data, Error>

    public init(status: Int, headers: [String: String], body: AsyncThrowingStream<Data, Error>) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
    public var isSuccess: Bool { (200..<300).contains(status) }

    /// Reads the rest of the body, for error responses that arrive on a stream.
    public func collect(limit: Int = 1 << 20) async throws -> Data {
        var data = Data()
        for try await chunk in body {
            data.append(chunk)
            if data.count >= limit { break }
        }
        return data
    }
}

public enum HTTPError: Error, Sendable, CustomStringConvertible {
    case status(code: Int, body: String, headers: [String: String])
    case undecodable(status: Int, type: String, detail: String, body: String)
    case transport(String, isOffline: Bool)

    public var description: String {
        switch self {
        case .status(let code, let body, _): return "HTTP \(code): \(body.prefix(500))"
        case .undecodable(let status, let type, let detail, let body):
            return "HTTP \(status): could not read \(type) (\(detail)). Body: \(body.prefix(300))"
        case .transport(let message, _): return message
        }
    }

    public var statusCode: Int? {
        switch self {
        case .status(let code, _, _), .undecodable(let code, _, _, _): return code
        case .transport: return nil
        }
    }

    public var isOffline: Bool {
        if case .transport(_, let isOffline) = self { return isOffline }
        return false
    }
}

/// How MAIPA-G talks to the network. URLSessionTransport is the real one; tests use a fake.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
    func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse
}

public extension HTTPTransport {
    /// Streams a response body straight to a file, so a 100 MB repo download never sits in memory.
    /// Returns the response head. `progress` receives the number of bytes written so far.
    func download(
        _ request: HTTPRequest,
        to destination: URL,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> HTTPResponse {
        let response = try await stream(request)
        guard response.isSuccess else {
            let body = try await response.collect(limit: 64 * 1024)
            return HTTPResponse(status: response.status, headers: response.headers, body: body)
        }
        let manager = FileManager.default
        try? manager.removeItem(at: destination)
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard manager.createFile(atPath: destination.path, contents: nil) else {
            throw HTTPError.transport("Could not create \(destination.lastPathComponent)", isOffline: false)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var written: Int64 = 0
        for try await chunk in response.body {
            try handle.write(contentsOf: chunk)
            written += Int64(chunk.count)
            progress?(written)
        }
        return HTTPResponse(status: response.status, headers: response.headers)
    }
}

// MARK: - URLSession

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// The real transport. One session for whole responses and one for streams, so the streaming
/// delegate never sees tasks it did not start.
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let plainSession: URLSession
    private let noRedirectSession: URLSession
    private let streamSession: URLSession
    private let streamDelegate: StreamingDelegate

    public init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        plainSession = URLSession(configuration: configuration)
        noRedirectSession = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)

        let delegate = StreamingDelegate()
        streamDelegate = delegate
        streamSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        plainSession.finishTasksAndInvalidate()
        noRedirectSession.finishTasksAndInvalidate()
        streamSession.finishTasksAndInvalidate()
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let urlRequest = Self.makeURLRequest(request)
        do {
            let session = request.followsRedirects ? plainSession : noRedirectSession
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw HTTPError.transport("Not an HTTP response", isOffline: false)
            }
            return HTTPResponse(status: http.statusCode, headers: Self.headers(of: http), body: data, finalURL: http.url)
        } catch let error as HTTPError {
            throw error
        } catch {
            throw Self.transportError(error)
        }
    }

    public func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        let urlRequest = Self.makeURLRequest(request)
        let (body, bodyContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let task = streamSession.dataTask(with: urlRequest)
        let taskBox = SendableTask(task)
        bodyContinuation.onTermination = { _ in taskBox.task.cancel() }
        do {
            let response: HTTPURLResponse = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    streamDelegate.register(task.taskIdentifier, head: continuation, body: bodyContinuation)
                    task.resume()
                }
            } onCancel: {
                taskBox.task.cancel()
            }
            return HTTPStreamResponse(status: response.statusCode, headers: Self.headers(of: response), body: body)
        } catch let error as HTTPError {
            throw error
        } catch {
            throw Self.transportError(error)
        }
    }

    static func makeURLRequest(_ request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.idleTimeout
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        return urlRequest
    }

    static func headers(of response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            result[String(describing: key).lowercased()] = String(describing: value)
        }
        return result
    }

    static func transportError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return CancellationError() }
            let offline: Set<URLError.Code> = [
                .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                .internationalRoamingOff, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
            ]
            return HTTPError.transport(urlError.localizedDescription, isOffline: offline.contains(urlError.code))
        }
        return HTTPError.transport(error.localizedDescription, isOffline: false)
    }
}

/// URLSessionTask is thread-safe but not marked Sendable on every platform.
private struct SendableTask: @unchecked Sendable {
    let task: URLSessionTask
    init(_ task: URLSessionTask) { self.task = task }
}

private final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Entry {
        var head: CheckedContinuation<HTTPURLResponse, Error>?
        let body: AsyncThrowingStream<Data, Error>.Continuation
    }

    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]

    func register(
        _ id: Int,
        head: CheckedContinuation<HTTPURLResponse, Error>,
        body: AsyncThrowingStream<Data, Error>.Continuation
    ) {
        lock.lock()
        entries[id] = Entry(head: head, body: body)
        lock.unlock()
    }

    private func takeHead(_ id: Int) -> CheckedContinuation<HTTPURLResponse, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let head = entries[id]?.head
        entries[id]?.head = nil
        return head
    }

    private func body(_ id: Int) -> AsyncThrowingStream<Data, Error>.Continuation? {
        lock.lock()
        defer { lock.unlock() }
        return entries[id]?.body
    }

    private func remove(_ id: Int) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries.removeValue(forKey: id)
    }

    // The response head is delivered with the first piece of the body (by then the task has its
    // response), or at the end for an empty body. This deliberately avoids the "did receive
    // response" delegate method: its completion handler is declared differently on Apple's SDKs
    // and on Linux, and a method that doesn't match exactly is silently never called, which
    // would leave every stream waiting forever.

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        deliverHead(for: dataTask)
        body(dataTask.taskIdentifier)?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error == nil { deliverHead(for: task) }
        guard let entry = remove(task.taskIdentifier) else { return }
        if let error {
            let mapped = URLSessionTransport.transportError(error)
            entry.head?.resume(throwing: mapped)
            entry.body.finish(throwing: mapped)
        } else {
            entry.head?.resume(throwing: HTTPError.transport("The server closed the connection early", isOffline: false))
            entry.body.finish()
        }
    }

    private func deliverHead(for task: URLSessionTask) {
        guard let head = takeHead(task.taskIdentifier) else { return }
        if let http = task.response as? HTTPURLResponse {
            head.resume(returning: http)
        } else {
            head.resume(throwing: HTTPError.transport("Not an HTTP response", isOffline: false))
        }
    }
}
