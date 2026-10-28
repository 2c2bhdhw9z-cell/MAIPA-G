import Foundation

/// Reads a `text/event-stream` body (the format OpenRouter streams replies in) one chunk at a time.
///
/// Follows the WHATWG rules MAIPA-G needs: lines end in LF, CRLF or CR; a blank line ends an event;
/// lines starting with `:` are comments (OpenRouter's `: OPENROUTER PROCESSING` keep-alives); an
/// event's `data:` lines are joined with newlines. Chunks can split anywhere, even inside a UTF-8
/// character, so bytes are buffered until a whole line is present.
public struct ServerSentEventParser: Sendable {
    private var pending: [UInt8] = []
    private var dataLines: [String] = []
    private var lastWasCR = false

    public init() {}

    /// Feeds raw bytes and returns the data of every event they completed.
    public mutating func feed(_ chunk: Data) -> [String] {
        var events: [String] = []
        for byte in chunk {
            switch byte {
            case 0x0A: // LF
                if lastWasCR {
                    lastWasCR = false // the LF of a CRLF pair; the line was already taken at CR
                    continue
                }
                takeLine(into: &events)
            case 0x0D: // CR
                lastWasCR = true
                takeLine(into: &events)
            default:
                lastWasCR = false
                pending.append(byte)
            }
        }
        return events
    }

    /// Call when the body ends. A final event without its closing blank line still counts.
    public mutating func finish() -> [String] {
        var events: [String] = []
        if !pending.isEmpty { takeLine(into: &events) }
        if !dataLines.isEmpty {
            events.append(dataLines.joined(separator: "\n"))
            dataLines.removeAll()
        }
        return events
    }

    private mutating func takeLine(into events: inout [String]) {
        let line = String(decoding: pending, as: UTF8.self)
        pending.removeAll(keepingCapacity: true)
        if line.isEmpty {
            if !dataLines.isEmpty {
                events.append(dataLines.joined(separator: "\n"))
                dataLines.removeAll()
            }
            return
        }
        if line.hasPrefix(":") { return }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        if field == "data" { dataLines.append(String(value)) }
    }
}

public extension AsyncThrowingStream where Element == Data, Failure == Error {
    /// The data of each server-sent event in this byte stream.
    func serverSentEvents() -> AsyncThrowingStream<String, Error> {
        let bytes = self
        return AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                var parser = ServerSentEventParser()
                do {
                    for try await chunk in bytes {
                        for event in parser.feed(chunk) { continuation.yield(event) }
                    }
                    for event in parser.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
