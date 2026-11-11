import MAIPAGZlib
import Foundation

/// gzip in both directions, for the files the phone and the computer's runner hand each other.
/// The computer reads and writes the same bytes with `gzip`/`gunzip`.
public enum GzipDeflater {
    public enum Failure: Error, CustomStringConvertible {
        case setup(Int32)
        case failed(Int32)
        case truncated

        public var description: String {
            switch self {
            case .setup(let code): return "Couldn't start compressing (zlib \(code))."
            case .failed(let code): return "Compressing failed (zlib \(code))."
            case .truncated: return "The compressed data ended early."
            }
        }
    }

    public static func compress(_ input: Data) throws -> Data {
        var stream = z_stream()
        // 15 + 16: largest window, with a gzip header, so `gunzip` reads it.
        let status = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw Failure.setup(status) }
        defer { deflateEnd(&stream) }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var source = [UInt8](input)
        let sourceCount = source.count
        try source.withUnsafeMutableBufferPointer { raw in
            stream.next_in = raw.baseAddress
            stream.avail_in = uInt(sourceCount)
            while true {
                let (produced, code) = buffer.withUnsafeMutableBufferPointer { out -> (Int, Int32) in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(out.count)
                    let code = deflate(&stream, Z_FINISH)
                    return (out.count - Int(stream.avail_out), code)
                }
                if produced > 0 { output.append(contentsOf: buffer[0..<produced]) }
                if code == Z_STREAM_END { break }
                guard code == Z_OK || code == Z_BUF_ERROR else { throw Failure.failed(code) }
            }
        }
        return output
    }

    public static func decompress(_ input: Data) throws -> Data {
        let inflater = try GzipInflater()
        var output = Data()
        try inflater.feed(input) { bytes in output.append(contentsOf: bytes) }
        guard inflater.isFinished else { throw Failure.truncated }
        return output
    }
}
