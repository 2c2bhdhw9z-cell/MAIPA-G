import AgentCore
import Foundation
import UIKit

/// The app's network transport. Ordinary requests use the normal session; uploads from a file
/// (MAIPA-G-data's big files) go through a background session, so they keep going while
/// MAIPA-G is in the background and finish even if iOS closes it.
final class AppTransport: HTTPTransport, @unchecked Sendable {
    private let base = URLSessionTransport()

    func send(_ request: HTTPRequest) async throws -> HTTPResponse { try await base.send(request) }
    func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse { try await base.stream(request) }
    func upload(_ request: HTTPRequest, fromFile file: URL) async throws -> HTTPResponse {
        try await BackgroundUploader.shared.upload(request, fromFile: file)
    }
}

/// One background URLSession for big uploads. If MAIPA-G is closed before an upload finishes,
/// iOS finishes it anyway; the next save then finds the file already in MAIPA-G-data's files
/// release (files there are named by their SHA-256) and doesn't upload it again.
final class BackgroundUploader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = BackgroundUploader()
    static let identifier = "dev.maipag.app.uploads"

    private let lock = NSLock()
    private var waiting: [Int: CheckedContinuation<HTTPResponse, Error>] = [:]
    private var bodies: [Int: Data] = [:]
    private var finishEvents: (() -> Void)?
    private var session: URLSession!

    override private init() {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func upload(_ request: HTTPRequest, fromFile file: URL) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let box = TaskBox(task: session.uploadTask(with: urlRequest, fromFile: file))
        let identifier = box.task.taskIdentifier
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, Error>) in
                lock.withLock { waiting[identifier] = continuation }
                box.task.resume()
            }
        } onCancel: {
            box.task.cancel()
        }
    }

    /// URLSessionTask is thread-safe; this lets it cross into the cancellation handler.
    private struct TaskBox: @unchecked Sendable { let task: URLSessionTask }
    private struct HandlerBox: @unchecked Sendable { let run: () -> Void }

    /// Called by the app delegate when iOS wakes MAIPA-G for finished background uploads.
    func handleEvents(completion: @escaping () -> Void) {
        lock.withLock { finishEvents = completion }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { bodies[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, body) = lock.withLock {
            (waiting.removeValue(forKey: task.taskIdentifier), bodies.removeValue(forKey: task.taskIdentifier) ?? Data())
        }
        // Nobody waiting: it finished after MAIPA-G restarted. The next save sees the file.
        guard let continuation else { return }
        if let error {
            let offline = (error as? URLError).map { [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains($0.code) } ?? false
            if (error as? URLError)?.code == .cancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                continuation.resume(throwing: HTTPError.transport(error.localizedDescription, isOffline: offline))
            }
            return
        }
        guard let http = task.response as? HTTPURLResponse else {
            continuation.resume(throwing: HTTPError.transport("The upload ended without an answer from GitHub.", isOffline: false))
            return
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
        continuation.resume(returning: HTTPResponse(status: http.statusCode, headers: headers, body: body, finalURL: http.url))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = lock.withLock { () -> (() -> Void)? in
            let handler = finishEvents
            finishEvents = nil
            return handler
        }
        if let handler {
            let box = HandlerBox(run: handler)
            DispatchQueue.main.async { box.run() }
        }
    }
}

/// Receives iOS's "your background uploads finished" wake-up.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundUploader.identifier else { completionHandler(); return }
        BackgroundUploader.shared.handleEvents(completion: completionHandler)
    }
}
