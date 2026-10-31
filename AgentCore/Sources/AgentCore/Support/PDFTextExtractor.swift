import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// Extracts readable UTF-8 text from attached PDF files so external AI gateways (OpenAI-compatible
/// `/v1/chat/completions`, `/v1/responses`) and text-only models can read attached PDFs instead of
/// dropping them or returning HTTP 400.
public enum PDFTextExtractor {
    public static let defaultMaxCharacters = 120_000

    public static func extractText(from data: Data, maxCharacters: Int = defaultMaxCharacters) -> String? {
        guard data.count >= 8 else { return nil }
        #if canImport(PDFKit)
        if let doc = PDFDocument(data: data), doc.pageCount > 0 {
            var pages: [String] = []
            var totalChars = 0
            for index in 0..<doc.pageCount {
                guard let raw = doc.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty else { continue }
                let entry = doc.pageCount > 1 ? "--- Page \(index + 1) ---\n\(raw)" : raw
                pages.append(entry)
                totalChars += entry.count + 2
                if totalChars >= maxCharacters { break }
            }
            let joined = pages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                return joined.count > maxCharacters ? String(joined.prefix(maxCharacters)) + "\n…[PDF text truncated]" : joined
            }
        }
        #endif
        return extractFromStreams(data, maxCharacters: maxCharacters)
    }

    public static func formattedAttachmentBlock(name: String, data: Data, maxCharacters: Int = defaultMaxCharacters) -> String {
        if let extracted = extractText(from: data, maxCharacters: maxCharacters), !extracted.isEmpty {
            return "[Attached PDF: \"\(name)\" — extracted text below (untrusted document data):]\n\(extracted)"
        }
        return "[Attached PDF: \"\(name)\" (\(data.count) bytes) — scanned/image-only or encrypted PDF without selectable text.]"
    }

    private static func extractFromStreams(_ data: Data, maxCharacters: Int) -> String? {
        let streamToken = Data("stream".utf8)
        let endStreamToken = Data("endstream".utf8)
        var cursor = data.startIndex
        var chunks: [String] = []
        var collectedCount = 0

        while cursor < data.endIndex,
              let sRange = data.range(of: streamToken, options: [], in: cursor..<data.endIndex) {
            var bodyStart = sRange.upperBound
            if bodyStart < data.endIndex, data[bodyStart] == 0x0D { bodyStart += 1 }
            if bodyStart < data.endIndex, data[bodyStart] == 0x0A { bodyStart += 1 }
            guard bodyStart < data.endIndex,
                  let eRange = data.range(of: endStreamToken, options: [], in: bodyStart..<data.endIndex) else {
                break
            }
            var bodyEnd = eRange.lowerBound
            if bodyEnd > bodyStart, data[bodyEnd - 1] == 0x0A { bodyEnd -= 1 }
            if bodyEnd > bodyStart, data[bodyEnd - 1] == 0x0D { bodyEnd -= 1 }

            if bodyEnd > bodyStart {
                let rawSlice = Data(data[bodyStart..<bodyEnd])
                let decodedStream = inflateZlibIfPossible(rawSlice) ?? rawSlice
                if let content = String(data: decodedStream, encoding: .isoLatin1) {
                    let parsed = parsePDFContentStream(content)
                    if !parsed.isEmpty {
                        chunks.append(parsed)
                        collectedCount += parsed.count + 1
                        if collectedCount >= maxCharacters { break }
                    }
                }
            }
            cursor = eRange.upperBound
        }

        // If the PDF had uncompressed inline BT..ET outside streams (simple synthetic PDFs), check raw Latin-1 too.
        if chunks.isEmpty, data.count <= 2 * 1024 * 1024, let raw = String(data: data, encoding: .isoLatin1) {
            let parsed = parsePDFContentStream(raw)
            if !parsed.isEmpty { chunks.append(parsed) }
        }

        let joined = chunks.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return nil }
        return joined.count > maxCharacters ? String(joined.prefix(maxCharacters)) + "\n…[PDF text truncated]" : joined
    }

    private static func inflateZlibIfPossible(_ raw: Data) -> Data? {
        guard let inflater = try? GzipInflater() else { return nil }
        var out = Data()
        do {
            try inflater.feed(raw) { buf in
                if out.count < 8 * 1024 * 1024 {
                    out.append(contentsOf: buf)
                }
            }
            return out.isEmpty ? nil : out
        } catch {
            return nil
        }
    }

    private static func parsePDFContentStream(_ content: String) -> String {
        guard content.contains("BT") else { return "" }
        var lines: [String] = []
        var searchIdx = content.startIndex
        while searchIdx < content.endIndex,
              let bt = content.range(of: "BT", range: searchIdx..<content.endIndex) {
            let afterBT = bt.upperBound
            let et = content.range(of: "ET", range: afterBT..<content.endIndex)?.lowerBound ?? content.endIndex
            let block = content[afterBT..<et]
            let extracted = parseBTBlock(block)
            if !extracted.isEmpty { lines.append(extracted) }
            searchIdx = et < content.endIndex ? content.index(after: et) : content.endIndex
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseBTBlock(_ block: Substring) -> String {
        var out = ""
        var i = block.startIndex
        while i < block.endIndex {
            let ch = block[i]
            if ch == "(" {
                let (literal, next) = readParenthesizedString(in: block, from: i)
                out += literal
                i = next
                // Add line break if followed shortly by T* / Td / TD / '
                let tail = block[i..<min(block.endIndex, block.index(i, offsetBy: 16, limitedBy: block.endIndex) ?? block.endIndex)]
                if tail.contains("T*") || tail.contains("'") { out += "\n" }
            } else if ch == "<" {
                let nextIdx = block.index(after: i)
                if nextIdx < block.endIndex, block[nextIdx] != "<" {
                    if let close = block[nextIdx..<block.endIndex].firstIndex(of: ">") {
                        let hex = String(block[nextIdx..<close]).filter { !$0.isWhitespace }
                        out += decodePDFHex(hex)
                        i = block.index(after: close)
                        continue
                    }
                }
                i = nextIdx
            } else if ch == "T" {
                let next = block.index(after: i)
                if next < block.endIndex, (block[next] == "*" || block[next] == "d" || block[next] == "D") {
                    if !out.hasSuffix("\n") && !out.isEmpty { out += "\n" }
                }
                i = next
            } else {
                i = block.index(after: i)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func readParenthesizedString(in text: Substring, from openParen: String.Index) -> (String, String.Index) {
        var depth = 0
        var i = openParen
        var result = ""
        while i < text.endIndex {
            let c = text[i]
            if c == "\\" {
                let esc = text.index(after: i)
                guard esc < text.endIndex else { break }
                let e = text[esc]
                switch e {
                case "n": result.append("\n"); i = text.index(after: esc)
                case "r": result.append("\r"); i = text.index(after: esc)
                case "t": result.append("\t"); i = text.index(after: esc)
                case "(", ")", "\\": result.append(e); i = text.index(after: esc)
                case "0"..."7":
                    var octal = String(e)
                    var cursor = text.index(after: esc)
                    for _ in 0..<2 where cursor < text.endIndex && ("0"..."7").contains(text[cursor]) {
                        octal.append(text[cursor])
                        cursor = text.index(after: cursor)
                    }
                    if let byte = UInt8(octal, radix: 8) {
                        result.append(Character(UnicodeScalar(byte)))
                    }
                    i = cursor
                default:
                    result.append(e)
                    i = text.index(after: esc)
                }
                continue
            }
            if c == "(" {
                if depth > 0 { result.append("(") }
                depth += 1
            } else if c == ")" {
                depth -= 1
                if depth <= 0 {
                    return (result, text.index(after: i))
                }
                result.append(")")
            } else {
                result.append(c)
            }
            i = text.index(after: i)
        }
        return (result, i)
    }

    private static func decodePDFHex(_ hex: String) -> String {
        var bytes: [UInt8] = []
        var chars = Array(hex)
        if chars.count % 2 == 1 { chars.append("0") }
        var idx = 0
        while idx + 1 < chars.count {
            if let b = UInt8(String([chars[idx], chars[idx + 1]]), radix: 16) {
                bytes.append(b)
            }
            idx += 2
        }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
            let body = Data(bytes.dropFirst(2))
            return String(data: body, encoding: .utf16BigEndian) ?? ""
        }
        return String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }
}
