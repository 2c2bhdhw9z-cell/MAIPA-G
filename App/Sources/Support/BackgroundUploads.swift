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
///
/// A save that stops waiting (its time ran out, or it was cancelled) leaves the upload running
/// instead of cancelling it, and a later request for the same upload waits for that one instead
/// of sending the file a second time. Before, a stopped save cancelled the upload, and the next
/// one started the whole file again from nothing.
final class BackgroundUploader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = BackgroundUploader()
    static let identifier = "dev.maipag.app.uploads"

    /// Everyone waiting on one upload task, and who wants to hear how far it has got.
    private struct Waiters {
        var continuations: [UUID: CheckedContinuation<HTTPResponse, Error>] = [:]
        var progress: [UUID: @Sendable (Int64) -> Void] = [:]
    }

    private let lock = NSLock()
    private var waiting: [Int: Waiters] = [:]
    /// The task sending each upload (by its address, which names the file by SHA-256), while it runs.
    private var taskForUpload: [String: Int] = [:]
    /// Answers of tasks that finished while nobody was waiting, for a caller that was about to.
    private var unclaimed: [Int: Result<HTTPResponse, Error>] = [:]
    /// Callers that stopped waiting before they had started to.
    private var cancelledWaiters: Set<UUID> = []
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
        try Task.checkCancellation()
        let key = request.url.absoluteString
        // The same upload may already be going: an earlier save stopped waiting for it, or
        // MAIPA-G was closed and opened again while iOS kept sending. Wait for that one.
        var taskID = lock.withLock { taskForUpload[key] }
        if taskID == nil, let running = await runningTaskID(for: key) {
            taskID = lock.withLock { () -> Int in
                if let current = taskForUpload[key] { return current }
                taskForUpload[key] = running
                return running
            }
        }
        var newTask: TaskBox?
        if taskID == nil {
            var urlRequest = URLRequest(url: request.url)
            urlRequest.httpMethod = request.method
            for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
            let task = session.uploadTask(with: urlRequest, fromFile: file)
            let chosen = lock.withLock { () -> Int in
                if let current = taskForUpload[key] { return current }
                taskForUpload[key] = task.taskIdentifier
                return task.taskIdentifier
            }
            if chosen == task.taskIdentifier {
                newTask = TaskBox(task: task)
            } else {
                // Another caller started the same upload a moment ago; this one was never sent.
                task.cancel()
            }
            taskID = chosen
        }
        guard let id = taskID else {
            throw HTTPError.transport("The upload couldn't be started.", isOffline: false)
        }
        let toStart = newTask
        let waiter = UUID()
        let progress = request.uploadProgress
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, Error>) in
                let ready: Result<HTTPResponse, Error>? = lock.withLock {
                    if cancelledWaiters.remove(waiter) != nil { return .failure(CancellationError()) }
                    if let done = unclaimed.removeValue(forKey: id) {
                        taskForUpload = taskForUpload.filter { $0.value != id }
                        return done
                    }
                    waiting[id, default: Waiters()].continuations[waiter] = continuation
                    if let progress { waiting[id, default: Waiters()].progress[waiter] = progress }
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
                toStart?.task.resume()
            }
        } onCancel: {
            // Only this caller stops waiting. The upload goes on: iOS finishes it, and the next
            // save picks it up (above) or finds the file already in the release.
            let continuation = lock.withLock { () -> CheckedContinuation<HTTPResponse, Error>? in
                if let found = waiting[id]?.continuations.removeValue(forKey: waiter) {
                    waiting[id]?.progress[waiter] = nil
                    return found
                }
                cancelledWaiters.insert(waiter)
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// The running task already sending to `key`, from this launch or an earlier one.
    private func runningTaskID(for key: String) async -> Int? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
            session.getAllTasks { tasks in
                let match = tasks.first { $0.state == .running && $0.originalRequest?.url?.absoluteString == key }
                continuation.resume(returning: match?.taskIdentifier)
            }
        }
    }

    /// URLSessionTask is thread-safe; this lets it cross into the continuation.
    private struct TaskBox: @unchecked Sendable { let task: URLSessionTask }
    private struct HandlerBox: @unchecked Sendable { let run: () -> Void }

    /// Called by the app delegate when iOS wakes MAIPA-G for finished background uploads.
    func handleEvents(completion: @escaping () -> Void) {
        lock.withLock { finishEvents = completion }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { bodies[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    /// Bytes going out are progress: the save's watchdog hears about them, so a big file that is
    /// still uploading is never taken for a stuck save.
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let handlers: [@Sendable (Int64) -> Void] = lock.withLock {
            waiting[task.taskIdentifier].map { Array($0.progress.values) } ?? []
        }
        for handler in handlers { handler(totalBytesSent) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        let body = lock.withLock { bodies.removeValue(forKey: id) ?? Data() }
        let result = Self.outcome(of: task, error: error, body: body)
        let continuations: [CheckedContinuation<HTTPResponse, Error>] = lock.withLock {
            taskForUpload = taskForUpload.filter { $0.value != id }
            guard let entry = waiting.removeValue(forKey: id), !entry.continuations.isEmpty else {
                // Nobody waiting: it finished after the save stopped waiting, or after MAIPA-G
                // restarted. Kept briefly for a caller about to wait for it; otherwise the next
                // save finds the file in the release.
                unclaimed[id] = result
                if unclaimed.count > 16, let oldest = unclaimed.keys.min() { unclaimed[oldest] = nil }
                return []
            }
            return Array(entry.continuations.values)
        }
        for continuation in continuations { continuation.resume(with: result) }
    }

    private static func outcome(of task: URLSessionTask, error: Error?, body: Data) -> Result<HTTPResponse, Error> {
        if let error {
            let code = (error as? URLError)?.code
            if code == .cancelled { return .failure(CancellationError()) }
            // Only these mean the phone has no connection. A dropped connection (-1005) is
            // temporary, so the upload is tried again rather than reported as offline.
            let offline = code.map { [URLError.Code.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff].contains($0) } ?? false
            return .failure(HTTPError.transport(error.localizedDescription, isOffline: offline))
        }
        guard let http = task.response as? HTTPURLResponse else {
            return .failure(HTTPError.transport("The upload ended without an answer from GitHub.", isOffline: false))
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
        return .success(HTTPResponse(status: http.statusCode, headers: headers, body: body, finalURL: http.url))
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
