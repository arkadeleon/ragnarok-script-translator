//
//  ScriptTokenizer.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/21.
//

struct Token {
    enum Kind: Equatable {
        /// Header line of a script (`map,x,y,dir<TAB>script<TAB>name<TAB>sprite,{`), carrying the NPC display name.
        case header(npc: String?)
        case identifier
        case string
        case number
        case punctuation
    }

    var kind: Token.Kind

    /// For strings, the unescaped content. For everything else, the raw source text.
    var text: String

    var line: Int

    /// Byte range in the source, used to reproduce placeholder expressions verbatim.
    var range: Range<Int>
}

/// Splits an rAthena NPC file into tokens. Only understands what the extractor needs:
/// comments, string literals with C escapes, identifiers (including variable prefixes), numbers and punctuation.
struct ScriptTokenizer {
    private let bytes: [UInt8]
    private var index = 0
    private var line = 1
    private var depth = 0

    init(source: String) {
        bytes = Array(source.utf8)
    }

    mutating func tokenize() -> [Token] {
        var tokens: [Token] = []
        while index < bytes.count {
            if depth == 0 {
                skipWhitespaceAndComments()
                guard index < bytes.count else {
                    break
                }
                if let header = readHeaderLine() {
                    tokens.append(header)
                }
                continue
            }

            skipWhitespaceAndComments()
            guard index < bytes.count else {
                break
            }
            guard let token = readToken() else {
                continue
            }
            if token.kind == .punctuation {
                if token.text == "{" {
                    depth += 1
                } else if token.text == "}" {
                    depth -= 1
                }
            }
            tokens.append(token)
        }
        return tokens
    }

    // MARK: - Header

    /// At depth 0 every non-comment line is a definition line (script, warp, shop, duplicate, ...).
    /// Only `script` definitions have a body; the tokenizer resumes at their opening brace.
    private mutating func readHeaderLine() -> Token? {
        let start = index
        let startLine = line
        while index < bytes.count, bytes[index] != UInt8(ascii: "\n") {
            index += 1
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        let fields = text.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }

        guard fields.count >= 3, fields[1] == "script" else {
            return nil
        }

        // Enter the body right after the opening brace. The brace itself is not emitted;
        // the matching `}` brings the depth back to 0.
        if let brace = bytes[start..<index].firstIndex(of: UInt8(ascii: "{")) {
            index = brace + 1
            depth = 1
        }

        return Token(kind: .header(npc: displayName(of: fields[2])), text: text, line: startLine, range: start..<index)
    }

    /// `Guard#pront::prtguard` -> `Guard`
    private func displayName(of name: String) -> String? {
        var name = Substring(name)
        if let range = name.range(of: "::") {
            name = name[..<range.lowerBound]
        }
        if let hash = name.firstIndex(of: "#") {
            name = name[..<hash]
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Body

    private mutating func skipWhitespaceAndComments() {
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\n") {
                line += 1
                index += 1
            } else if byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r") {
                index += 1
            } else if byte == UInt8(ascii: "/"), peek(1) == UInt8(ascii: "/") {
                while index < bytes.count, bytes[index] != UInt8(ascii: "\n") {
                    index += 1
                }
            } else if byte == UInt8(ascii: "/"), peek(1) == UInt8(ascii: "*") {
                index += 2
                while index < bytes.count, !(bytes[index] == UInt8(ascii: "*") && peek(1) == UInt8(ascii: "/")) {
                    if bytes[index] == UInt8(ascii: "\n") {
                        line += 1
                    }
                    index += 1
                }
                index = min(index + 2, bytes.count)
            } else {
                return
            }
        }
    }

    private func peek(_ offset: Int) -> UInt8? {
        let position = index + offset
        return position < bytes.count ? bytes[position] : nil
    }

    private mutating func readToken() -> Token? {
        let byte = bytes[index]
        if byte == UInt8(ascii: "\"") {
            return readString()
        }
        if byte.isIdentifierStart || byte.isVariablePrefix {
            if let identifier = readIdentifier() {
                return identifier
            }
        }
        if byte.isDigit {
            return readNumber()
        }
        return readPunctuation()
    }

    private mutating func readString() -> Token {
        let start = index
        let startLine = line
        index += 1 // opening quote
        var content: [UInt8] = []
        while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\\") {
                index += 1
                content.append(contentsOf: readEscape())
                continue
            }
            if byte == UInt8(ascii: "\n") {
                // rAthena rejects this; stop the string so the rest of the file still parses.
                break
            }
            content.append(byte)
            index += 1
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "\"") {
            index += 1
        }
        return Token(kind: .string, text: String(decoding: content, as: UTF8.self), line: startLine, range: start..<index)
    }

    /// Mirrors rAthena's `skip_escaped_c` / `sv_unescape_c`. `index` points just past the backslash.
    private mutating func readEscape() -> [UInt8] {
        guard index < bytes.count else {
            return []
        }
        let byte = bytes[index]
        switch byte {
        case UInt8(ascii: "x"):
            index += 1
            var value: UInt8 = 0
            var digits = 0
            while index < bytes.count, let digit = bytes[index].hexValue {
                value = value &* 16 &+ digit
                digits += 1
                index += 1
            }
            return digits > 0 ? [value] : [UInt8(ascii: "x")]
        case UInt8(ascii: "0")...UInt8(ascii: "3"):
            var value: UInt8 = 0
            var digits = 0
            while index < bytes.count, digits < 3, bytes[index] >= UInt8(ascii: "0"), bytes[index] <= UInt8(ascii: "7") {
                value = value &* 8 &+ (bytes[index] - UInt8(ascii: "0"))
                digits += 1
                index += 1
            }
            return [value]
        case UInt8(ascii: "n"):
            index += 1
            return [0x0A]
        case UInt8(ascii: "r"):
            index += 1
            return [0x0D]
        case UInt8(ascii: "t"):
            index += 1
            return [0x09]
        case UInt8(ascii: "a"):
            index += 1
            return [0x07]
        case UInt8(ascii: "b"):
            index += 1
            return [0x08]
        case UInt8(ascii: "v"):
            index += 1
            return [0x0B]
        case UInt8(ascii: "f"):
            index += 1
            return [0x0C]
        case UInt8(ascii: "\""), UInt8(ascii: "'"), UInt8(ascii: "\\"), UInt8(ascii: "?"):
            index += 1
            return [byte]
        default:
            // Unknown escape: keep the backslash and let the next loop iteration handle the character.
            return [UInt8(ascii: "\\")]
        }
    }

    /// Variables may be prefixed with `$`, `$@`, `.`, `.@`, `'`, `#`, `##`, `@` and suffixed with `$`.
    private mutating func readIdentifier() -> Token? {
        let start = index
        var cursor = index
        while cursor < bytes.count, bytes[cursor].isVariablePrefix {
            cursor += 1
        }
        guard cursor < bytes.count, bytes[cursor].isIdentifierStart else {
            return nil
        }
        while cursor < bytes.count, bytes[cursor].isIdentifierPart {
            cursor += 1
        }
        if cursor < bytes.count, bytes[cursor] == UInt8(ascii: "$") {
            cursor += 1
        }
        index = cursor
        return Token(kind: .identifier, text: String(decoding: bytes[start..<cursor], as: UTF8.self), line: line, range: start..<cursor)
    }

    private mutating func readNumber() -> Token {
        let start = index
        while index < bytes.count, bytes[index].isIdentifierPart {
            index += 1
        }
        return Token(kind: .number, text: String(decoding: bytes[start..<index], as: UTF8.self), line: line, range: start..<index)
    }

    private mutating func readPunctuation() -> Token {
        let start = index
        index += 1
        return Token(kind: .punctuation, text: String(decoding: bytes[start..<index], as: UTF8.self), line: line, range: start..<index)
    }
}

extension UInt8 {
    fileprivate var isIdentifierStart: Bool {
        (self >= UInt8(ascii: "a") && self <= UInt8(ascii: "z")) || (self >= UInt8(ascii: "A") && self <= UInt8(ascii: "Z")) || self == UInt8(ascii: "_")
    }

    fileprivate var isIdentifierPart: Bool {
        isIdentifierStart || isDigit
    }

    fileprivate var isDigit: Bool {
        self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9")
    }

    fileprivate var isVariablePrefix: Bool {
        self == UInt8(ascii: "$") || self == UInt8(ascii: "@") || self == UInt8(ascii: ".") || self == UInt8(ascii: "'") || self == UInt8(ascii: "#")
    }

    fileprivate var hexValue: UInt8? {
        switch self {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            self - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            self - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            self - UInt8(ascii: "A") + 10
        default:
            nil
        }
    }
}
