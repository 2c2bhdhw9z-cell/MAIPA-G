import MAIPAGZlib
import Foundation

/// Streams gzip (or zlib) data back to its original bytes.
final class GzipInflater {
    enum Failure: Error, CustomStringConvertible {
        case setup(Int32)
        case corrupt(Int32, String)

        var description: String {
            switch self {
            case .setup(let code): return "Could not start unzipping (zlib \(code))"
            case .corrupt(let code, let message): return "The download is damaged (zlib \(code): \(message))"
            }
        }
    }

    private var stream = z_stream()
    private var output = [UInt8](repeating: 0, count: 256 * 1024)
    private(set) var isFinished = false

    init() throws {
        // 15 + 32: largest window, and detect gzip or zlib headers automatically.
        let status = czlib_inflate_init2(&stream, 15 + 32)
        guard status == Z_OK else { throw Failure.setup(status) }
    }

    deinit {
        inflateEnd(&stream)
    }

    /// Unzips `input`, handing each piece of output to `sink`. Concatenated gzip members (allowed
    /// by the format, though GitHub sends one) are unzipped one after another.
    func feed(_ input: Data, sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        guard !input.isEmpty else { return }
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(raw.count)
            while stream.avail_in > 0 {
                if isFinished {
                    // Another gzip member follows the one that just ended.
                    guard inflateReset(&stream) == Z_OK else { throw Failure.corrupt(Z_STREAM_ERROR, "reset failed") }
                    isFinished = false
                }
                let produced: Int
                let status: Int32
                (produced, status) = output.withUnsafeMutableBytes { buffer -> (Int, Int32) in
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(buffer.count)
                    let status = inflate(&stream, Z_NO_FLUSH)
                    return (buffer.count - Int(stream.avail_out), status)
                }
                if produced > 0 {
                    try output.withUnsafeBytes { buffer in
                        try sink(UnsafeRawBufferPointer(rebasing: buffer[0..<produced]))
                    }
                }
                switch status {
                case Z_OK:
                    continue
                case Z_STREAM_END:
                    isFinished = true
                case Z_BUF_ERROR:
                    // No progress possible: zlib needs more input than this chunk had.
                    if produced == 0 { return }
                default:
                    let message = stream.msg.map { String(cString: $0) } ?? "unknown"
                    throw Failure.corrupt(status, message)
                }
            }
        }
    }
}

/// One file, folder or link in a tar archive.
struct TarEntry: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case file, directory, symlink, hardLink, other }
    var path: String
    var kind: Kind
    var size: Int
    var linkTarget: String
    var mode: Int
}

/// Receives the entries of a tar archive as it streams past.
protocol TarHandler {
    /// Return false to skip this entry's bytes.
    mutating func begin(_ entry: TarEntry) throws -> Bool
    mutating func data(_ bytes: UnsafeRawBufferPointer) throws
    mutating func end() throws
    /// The archive's global comment, if it has one. GitHub puts the commit id there.
    mutating func globalComment(_ comment: String)
}

extension TarHandler {
    mutating func globalComment(_ comment: String) {}
}

/// Reads a tar archive (ustar, with the PAX and GNU extensions for long names) incrementally.
struct TarReader {
    enum Failure: Error, CustomStringConvertible {
        case badHeader(String)
        var description: String {
            switch self {
            case .badHeader(let detail): return "The repo download is not a valid archive (\(detail))"
            }
        }
    }

    private enum State {
        case header
        case body(remaining: Int, padding: Int, capture: Capture?)
        case padding(remaining: Int)
        case done
    }

    /// Metadata entries whose contents describe the next real entry.
    private enum Capture {
        case paxLocal, paxGlobal, gnuLongName, gnuLongLink
    }

    private var state: State = .header
    private var headerBuffer: [UInt8] = []
    private var captured: [UInt8] = []
    private var pendingPath: String?
    private var pendingLink: String?
    private var pendingSize: Int?
    private var zeroBlocks = 0

    var isDone: Bool {
        if case .done = state { return true }
        return false
    }

    mutating func feed<H: TarHandler>(_ input: UnsafeRawBufferPointer, into handler: inout H) throws {
        var offset = 0
        while offset < input.count {
            switch state {
            case .done:
                return
            case .header:
                let needed = 512 - headerBuffer.count
                let take = min(needed, input.count - offset)
                headerBuffer.append(contentsOf: input[offset..<(offset + take)])
                offset += take
                if headerBuffer.count == 512 {
                    let block = headerBuffer
                    headerBuffer.removeAll(keepingCapacity: true)
                    try handleHeader(block, handler: &handler)
                }
            case .body(let remaining, let padding, let capture):
                let take = min(remaining, input.count - offset)
                let slice = UnsafeRawBufferPointer(rebasing: input[offset..<(offset + take)])
                if capture != nil {
                    captured.append(contentsOf: slice)
                } else {
                    try handler.data(slice)
                }
                offset += take
                let left = remaining - take
                if left == 0 {
                    if let capture {
                        applyCapture(capture, handler: &handler)
                    } else {
                        try handler.end()
                    }
                    state = padding > 0 ? .padding(remaining: padding) : .header
                } else {
                    state = .body(remaining: left, padding: padding, capture: capture)
                }
            case .padding(let remaining):
                let take = min(remaining, input.count - offset)
                offset += take
                state = remaining - take == 0 ? .header : .padding(remaining: remaining - take)
            }
        }
    }

    private mutating func handleHeader<H: TarHandler>(_ block: [UInt8], handler: inout H) throws {
        if block.allSatisfy({ $0 == 0 }) {
            zeroBlocks += 1
            if zeroBlocks >= 2 { state = .done }
            return
        }
        zeroBlocks = 0
        guard Self.checksumMatches(block) else { throw Failure.badHeader("checksum") }

        let type = block[156]
        let declaredSize = try Self.number(block[124..<136])
        let metaPadding = (512 - declaredSize % 512) % 512

        switch type {
        case UInt8(ascii: "x"):
            state = declaredSize > 0 ? .body(remaining: declaredSize, padding: metaPadding, capture: .paxLocal) : .header
            captured.removeAll()
            return
        case UInt8(ascii: "g"):
            state = declaredSize > 0 ? .body(remaining: declaredSize, padding: metaPadding, capture: .paxGlobal) : .header
            captured.removeAll()
            return
        case UInt8(ascii: "L"):
            state = declaredSize > 0 ? .body(remaining: declaredSize, padding: metaPadding, capture: .gnuLongName) : .header
            captured.removeAll()
            return
        case UInt8(ascii: "K"):
            state = declaredSize > 0 ? .body(remaining: declaredSize, padding: metaPadding, capture: .gnuLongLink) : .header
            captured.removeAll()
            return
        default:
            break
        }

        let name = Self.string(block[0..<100])
        let prefix = Self.string(block[345..<500])
        let isUstar = Self.string(block[257..<262]) == "ustar"
        var path = (isUstar && !prefix.isEmpty) ? prefix + "/" + name : name
        if let pendingPath { path = pendingPath }
        var link = Self.string(block[157..<257])
        if let pendingLink { link = pendingLink }
        let size = pendingSize ?? declaredSize
        pendingPath = nil
        pendingLink = nil
        pendingSize = nil

        let kind: TarEntry.Kind
        switch type {
        case 0, UInt8(ascii: "0"), UInt8(ascii: "7"): kind = path.hasSuffix("/") ? .directory : .file
        case UInt8(ascii: "5"): kind = .directory
        case UInt8(ascii: "2"): kind = .symlink
        case UInt8(ascii: "1"): kind = .hardLink
        default: kind = .other
        }
        let mode = (try? Self.number(block[100..<108])) ?? 0o644
        let entry = TarEntry(path: path, kind: kind, size: kind == .file ? size : 0, linkTarget: link, mode: mode)
        let wants = try handler.begin(entry)
        let bodySize = kind == .file ? size : (kind == .other ? size : 0)
        if bodySize > 0 {
            if wants {
                state = .body(remaining: bodySize, padding: (512 - bodySize % 512) % 512, capture: nil)
            } else {
                try handler.end()
                state = .padding(remaining: bodySize + (512 - bodySize % 512) % 512)
            }
        } else {
            try handler.end()
            state = .header
        }
    }

    private mutating func applyCapture<H: TarHandler>(_ capture: Capture, handler: inout H) {
        let bytes = captured
        captured.removeAll()
        switch capture {
        case .gnuLongName:
            pendingPath = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        case .gnuLongLink:
            pendingLink = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        case .paxLocal, .paxGlobal:
            for (key, value) in Self.paxRecords(bytes) {
                switch (capture, key) {
                case (.paxLocal, "path"): pendingPath = value
                case (.paxLocal, "linkpath"): pendingLink = value
                case (.paxLocal, "size"): pendingSize = Int(value)
                case (.paxGlobal, "comment"): handler.globalComment(value)
                default: break
                }
            }
        }
    }

    /// PAX records are "<length> <key>=<value>\n", where length counts the whole record.
    static func paxRecords(_ bytes: [UInt8]) -> [(String, String)] {
        var records: [(String, String)] = []
        var index = 0
        while index < bytes.count {
            guard let space = bytes[index...].firstIndex(of: UInt8(ascii: " ")),
                  let length = Int(String(decoding: bytes[index..<space], as: UTF8.self)), length > 0,
                  index + length <= bytes.count
            else { break }
            let record = bytes[(space + 1)..<(index + length)]
            if let equals = record.firstIndex(of: UInt8(ascii: "=")) {
                let key = String(decoding: record[record.startIndex..<equals], as: UTF8.self)
                var valueBytes = record[(equals + 1)...]
                if valueBytes.last == UInt8(ascii: "\n") { valueBytes = valueBytes.dropLast() }
                records.append((key, String(decoding: valueBytes, as: UTF8.self)))
            }
            index += length
        }
        return records
    }

    static func string(_ field: ArraySlice<UInt8>) -> String {
        String(decoding: field.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// Tar numbers are octal text, or big-endian binary when the first byte's high bit is set.
    static func number(_ field: ArraySlice<UInt8>) throws -> Int {
        guard let first = field.first else { return 0 }
        if first & 0x80 != 0 {
            var value = Int(first & 0x7F)
            for byte in field.dropFirst() { value = (value << 8) | Int(byte) }
            return value
        }
        let text = String(decoding: field.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return 0 }
        guard let value = Int(text, radix: 8) else { throw Failure.badHeader("number \(text)") }
        return value
    }

    static func checksumMatches(_ block: [UInt8]) -> Bool {
        guard let stored = try? number(block[148..<156]) else { return false }
        var unsigned = 0
        var signed = 0
        for (index, byte) in block.enumerated() {
            let value = (148..<156).contains(index) ? 0x20 : byte
            unsigned += Int(value)
            signed += Int(Int8(bitPattern: value))
        }
        return stored == unsigned || stored == signed
    }
}
