import Foundation

/// Strictly decodes the text formats MAIPA-G can edit and restores the original file format
/// after a whole-file edit. Unsupported encodings and binary-looking data are rejected instead
/// of being decoded with replacement characters.
enum TextFileCodec {
    enum Encoding: Sendable, Equatable {
        case utf8
        case utf16LittleEndian
        case utf16BigEndian
    }

    struct Document: Sendable {
        let text: String
        let data: Data
        let encoding: Encoding
        let hasByteOrderMark: Bool
        fileprivate let lines: [Line]

        fileprivate init(data: Data, rawText: String, encoding: Encoding, hasByteOrderMark: Bool) {
            let lines = TextFileCodec.lines(in: rawText)
            self.text = lines.reduce(into: "") { result, line in
                result += line.text
                if line.ending != nil { result += "\n" }
            }
            self.data = data
            self.encoding = encoding
            self.hasByteOrderMark = hasByteOrderMark
            self.lines = lines
        }
    }

    fileprivate enum LineEnding: Sendable, Equatable, Hashable {
        case lineFeed
        case carriageReturnLineFeed
        case carriageReturn

        var text: String {
            switch self {
            case .lineFeed: return "\n"
            case .carriageReturnLineFeed: return "\r\n"
            case .carriageReturn: return "\r"
            }
        }
    }

    fileprivate struct Line: Sendable, Equatable {
        var text: String
        var ending: LineEnding?
    }

    private static let utf8BOM: [UInt8] = [0xef, 0xbb, 0xbf]
    private static let utf16LittleEndianBOM: [UInt8] = [0xff, 0xfe]
    private static let utf16BigEndianBOM: [UInt8] = [0xfe, 0xff]
    private static let utf32LittleEndianBOM: [UInt8] = [0xff, 0xfe, 0x00, 0x00]
    private static let utf32BigEndianBOM: [UInt8] = [0x00, 0x00, 0xfe, 0xff]

    /// Returns nil unless every byte is valid supported text. UTF-16 is accepted only with a BOM,
    /// which avoids guessing an encoding from binary data that happens to contain zero bytes.
    static func decode(_ data: Data) -> Document? {
        let rawText: String
        let encoding: Encoding
        let hasByteOrderMark: Bool

        if data.starts(with: utf32LittleEndianBOM) || data.starts(with: utf32BigEndianBOM) {
            return nil
        } else if data.starts(with: utf8BOM) {
            guard let decoded = String(data: data.dropFirst(utf8BOM.count), encoding: .utf8) else { return nil }
            rawText = decoded
            encoding = .utf8
            hasByteOrderMark = true
        } else if data.starts(with: utf16LittleEndianBOM) {
            guard let decoded = decodeUTF16(data.dropFirst(utf16LittleEndianBOM.count), littleEndian: true) else { return nil }
            rawText = decoded
            encoding = .utf16LittleEndian
            hasByteOrderMark = true
        } else if data.starts(with: utf16BigEndianBOM) {
            guard let decoded = decodeUTF16(data.dropFirst(utf16BigEndianBOM.count), littleEndian: false) else { return nil }
            rawText = decoded
            encoding = .utf16BigEndian
            hasByteOrderMark = true
        } else {
            guard let decoded = String(data: data, encoding: .utf8) else { return nil }
            rawText = decoded
            encoding = .utf8
            hasByteOrderMark = false
        }

        guard isSupportedText(rawText) else { return nil }
        return Document(data: data, rawText: rawText, encoding: encoding, hasByteOrderMark: hasByteOrderMark)
    }

    /// Encodes replacement text with the original encoding, BOM, per-line endings and
    /// final-newline behavior. The replacement may use any common line ending; it is normalized
    /// before the original file's endings are reapplied.
    static func encode(_ replacement: String, preserving original: Document) -> Data {
        var replacementLines = lines(in: replacement)
        let originalHasFinalNewline = original.lines.last?.ending != nil
        let replacementIsEmpty = replacementLines.count == 1 && replacementLines[0].text.isEmpty && replacementLines[0].ending == nil
        let keepFinalNewline = originalHasFinalNewline && !replacementIsEmpty
        let endings = preservedEndings(
            from: original.lines,
            for: replacementLines.map(\.text),
            finalNewline: keepFinalNewline
        )
        for index in replacementLines.indices {
            replacementLines[index].ending = endings[index]
        }

        let rawText = replacementLines.reduce(into: "") { result, line in
            result += line.text
            if let ending = line.ending { result += ending.text }
        }
        return encode(rawText, as: original.encoding, byteOrderMark: original.hasByteOrderMark)
    }

    private static func decodeUTF16(_ data: Data.SubSequence, littleEndian: Bool) -> String? {
        guard data.count.isMultiple(of: 2) else { return nil }
        let bytes = Array(data)
        var codeUnits: [UInt16] = []
        codeUnits.reserveCapacity(bytes.count / 2)
        for offset in stride(from: 0, to: bytes.count, by: 2) {
            let first = UInt16(bytes[offset])
            let second = UInt16(bytes[offset + 1])
            codeUnits.append(littleEndian ? first | (second << 8) : (first << 8) | second)
        }

        var index = 0
        while index < codeUnits.count {
            let unit = codeUnits[index]
            if (0xd800...0xdbff).contains(unit) {
                guard index + 1 < codeUnits.count, (0xdc00...0xdfff).contains(codeUnits[index + 1]) else { return nil }
                index += 2
            } else if (0xdc00...0xdfff).contains(unit) {
                return nil
            } else {
                index += 1
            }
        }
        return String(decoding: codeUnits, as: UTF16.self)
    }

    private static func encode(_ text: String, as encoding: Encoding, byteOrderMark: Bool) -> Data {
        switch encoding {
        case .utf8:
            var result = Data()
            if byteOrderMark { result.append(contentsOf: utf8BOM) }
            result.append(contentsOf: text.utf8)
            return result
        case .utf16LittleEndian, .utf16BigEndian:
            var result = Data()
            if byteOrderMark {
                result.append(contentsOf: encoding == .utf16LittleEndian ? utf16LittleEndianBOM : utf16BigEndianBOM)
            }
            result.reserveCapacity(result.count + text.utf16.count * 2)
            for unit in text.utf16 {
                if encoding == .utf16LittleEndian {
                    result.append(UInt8(truncatingIfNeeded: unit))
                    result.append(UInt8(truncatingIfNeeded: unit >> 8))
                } else {
                    result.append(UInt8(truncatingIfNeeded: unit >> 8))
                    result.append(UInt8(truncatingIfNeeded: unit))
                }
            }
            return result
        }
    }

    /// Rejects NUL and non-text control characters even when the bytes are technically valid
    /// UTF-8/UTF-16. This catches NUL-free binary payloads without excluding tabs or newlines.
    private static func isSupportedText(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x09, 0x0a, 0x0d:
                return true
            case 0x00...0x1f, 0x7f...0x9f:
                return false
            default:
                return true
            }
        }
    }

    private static func lines(in text: String) -> [Line] {
        let scalars = text.unicodeScalars
        var result: [Line] = []
        var lineStart = scalars.startIndex
        var index = lineStart

        while index != scalars.endIndex {
            let value = scalars[index].value
            guard value == 0x0a || value == 0x0d else {
                index = scalars.index(after: index)
                continue
            }

            let content = String(scalars[lineStart..<index])
            if value == 0x0d {
                let next = scalars.index(after: index)
                if next != scalars.endIndex, scalars[next].value == 0x0a {
                    result.append(Line(text: content, ending: .carriageReturnLineFeed))
                    index = scalars.index(after: next)
                } else {
                    result.append(Line(text: content, ending: .carriageReturn))
                    index = next
                }
            } else {
                result.append(Line(text: content, ending: .lineFeed))
                index = scalars.index(after: index)
            }
            lineStart = index
        }

        if lineStart != scalars.endIndex || result.isEmpty {
            result.append(Line(text: String(scalars[lineStart..<scalars.endIndex]), ending: nil))
        }
        return result
    }

    /// Uses a line diff so endings stay attached to unchanged lines in a mixed-ending file. For
    /// inserted or replaced lines, the nearest corresponding original line supplies the style.
    private static func preservedEndings(
        from original: [Line],
        for replacement: [String],
        finalNewline: Bool
    ) -> [LineEnding?] {
        let originalText = original.map(\.text)
        let difference = replacement.difference(from: originalText).inferringMoves()
        var oldRemoved = Set<Int>()
        var newInserted = Set<Int>()
        var originalIndexByReplacementIndex: [Int: Int] = [:]

        for change in difference {
            switch change {
            case .remove(let offset, _, let associated):
                oldRemoved.insert(offset)
                if let associated { originalIndexByReplacementIndex[associated] = offset }
            case .insert(let offset, _, let associated):
                newInserted.insert(offset)
                if let associated { originalIndexByReplacementIndex[offset] = associated }
            }
        }

        var oldIndex = 0
        var newIndex = 0
        while oldIndex < original.count, newIndex < replacement.count {
            if oldRemoved.contains(oldIndex) {
                oldIndex += 1
            } else if newInserted.contains(newIndex) {
                newIndex += 1
            } else {
                originalIndexByReplacementIndex[newIndex] = oldIndex
                oldIndex += 1
                newIndex += 1
            }
        }

        let defaultEnding = preferredEnding(in: original)
        let mapped = originalIndexByReplacementIndex.sorted { $0.key < $1.key }
        return replacement.indices.map { index in
            let needsEnding = index < replacement.count - 1 || finalNewline
            guard needsEnding else { return nil }
            if let originalIndex = originalIndexByReplacementIndex[index], let ending = original[originalIndex].ending {
                return ending
            }

            let previous = mapped.last { $0.key < index }
            let next = mapped.first { $0.key > index }
            let estimatedOriginalIndex: Int
            if let previous, let next, previous.value < next.value {
                let oldGap = next.value - previous.value - 1
                let position = index - previous.key
                estimatedOriginalIndex = oldGap > 0 ? previous.value + min(position, oldGap) : previous.value
            } else if let previous {
                estimatedOriginalIndex = min(previous.value + index - previous.key, original.count - 1)
            } else if let next {
                estimatedOriginalIndex = max(0, next.value - (next.key - index))
            } else {
                estimatedOriginalIndex = min(index, original.count - 1)
            }
            return nearestEnding(in: original, to: estimatedOriginalIndex) ?? defaultEnding
        }
    }

    private static func preferredEnding(in lines: [Line]) -> LineEnding {
        var counts: [LineEnding: Int] = [:]
        var firstSeen: [LineEnding] = []
        for ending in lines.compactMap(\.ending) {
            if counts[ending] == nil { firstSeen.append(ending) }
            counts[ending, default: 0] += 1
        }
        return firstSeen.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? .lineFeed
    }

    private static func nearestEnding(in lines: [Line], to index: Int) -> LineEnding? {
        guard !lines.isEmpty else { return nil }
        let start = min(max(index, 0), lines.count - 1)
        if let ending = lines[start].ending { return ending }
        for distance in 1..<lines.count {
            let before = start - distance
            if before >= 0, let ending = lines[before].ending { return ending }
            let after = start + distance
            if after < lines.count, let ending = lines[after].ending { return ending }
        }
        return nil
    }
}
