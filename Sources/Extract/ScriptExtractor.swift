//
//  ScriptExtractor.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/21.
//

/// A string expression split into literal text and the expressions concatenated into it.
private enum Segment {
    case literal(String)
    case placeholder(String)
}

/// Walks the token stream of one NPC file and collects dialog pages and menu options.
///
/// A page is a run of consecutive `mes` statements with nothing in between, which is what the
/// client sees between two `next`/`close` calls. A `mes` that is the sole body of an `if`/`else`/loop
/// forms a page on its own, since it may or may not be shown at runtime.
struct ScriptExtractor {
    private let source: [UInt8]
    private let tokens: [Token]

    init(source: String) {
        self.source = Array(source.utf8)
        self.tokens = ScriptTokenizer.tokenize(source)
    }

    func extract() -> [ExtractedScript] {
        var scripts: [ExtractedScript] = []
        var npc: String?
        var page: [[Segment]] = []
        var pageLine = 0

        func flushPage() {
            if let script = Self.makeScript(kind: .message, npc: npc, line: pageLine, lines: page) {
                scripts.append(script)
            }
            page.removeAll()
        }

        var index = 0
        while index < tokens.count {
            let token = tokens[index]

            if case .header(let name) = token.kind {
                flushPage()
                npc = name
                index += 1
                continue
            }

            guard token.kind == .identifier else {
                flushPage()
                index += 1
                continue
            }

            switch token.text.lowercased() {
            case "mes":
                let (arguments, end) = parseArguments(from: index + 1, until: ";")
                let standalone = isStandalone(at: index)
                if standalone {
                    flushPage()
                }
                if page.isEmpty {
                    pageLine = token.line
                }
                page.append(contentsOf: arguments)
                if standalone {
                    flushPage()
                }
                index = end

            case "select", "prompt":
                flushPage()
                guard index + 1 < tokens.count, tokens[index + 1].text == "(" else {
                    index += 1
                    continue
                }
                let (arguments, end) = parseArguments(from: index + 2, until: ")")
                scripts.append(contentsOf: Self.makeOptions(npc: npc, line: token.line, arguments: arguments))
                index = end

            case "menu":
                flushPage()
                let (arguments, end) = parseArguments(from: index + 1, until: ";")
                // `menu "text",L_label,"text",L_label,...`: every other argument is a label.
                let texts = arguments.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
                scripts.append(contentsOf: Self.makeOptions(npc: npc, line: token.line, arguments: texts))
                index = end

            default:
                flushPage()
                index += 1
            }
        }
        flushPage()

        return scripts
    }

    // MARK: - Parsing

    /// `if (...) mes "..."` or `else mes "..."` shows the message conditionally, so it must not be merged
    /// with its neighbours.
    private func isStandalone(at index: Int) -> Bool {
        guard index > 0 else { return false }
        let previous = tokens[index - 1]
        switch previous.kind {
        case .punctuation:
            return previous.text == ")"
        case .identifier:
            return previous.text.lowercased() == "else"
        default:
            return false
        }
    }

    /// Reads comma-separated arguments up to `terminator` at nesting depth 0.
    /// Returns the arguments as segments and the index just past the terminator.
    private func parseArguments(from start: Int, until terminator: String) -> (arguments: [[Segment]], end: Int) {
        var arguments: [[Segment]] = []
        var current: [Token] = []
        var depth = 0
        var index = start

        func finishArgument() {
            if !current.isEmpty {
                arguments.append(segments(of: current))
                current.removeAll()
            }
        }

        while index < tokens.count {
            let token = tokens[index]
            if case .header = token.kind {
                // Ran off the end of a script body; give up on this statement.
                break
            }
            if token.kind == .punctuation {
                switch token.text {
                case "(", "[":
                    depth += 1
                case ")", "]":
                    if depth == 0 {
                        if terminator == ")" {
                            index += 1
                            finishArgument()
                            return (arguments, index)
                        }
                        // Unbalanced; treat as end of statement.
                        finishArgument()
                        return (arguments, index)
                    }
                    depth -= 1
                case ",":
                    if depth == 0 {
                        finishArgument()
                        index += 1
                        continue
                    }
                case ";", "}", "{":
                    if depth == 0 || token.text != ";" {
                        finishArgument()
                        return (arguments, token.text == terminator ? index + 1 : index)
                    }
                default:
                    break
                }
            }
            current.append(token)
            index += 1
        }
        finishArgument()
        return (arguments, index)
    }

    /// Splits an expression on top-level `+` and classifies each term as literal text or placeholder.
    private func segments(of tokens: [Token]) -> [Segment] {
        var terms: [[Token]] = [[]]
        var depth = 0
        for token in tokens {
            if token.kind == .punctuation {
                switch token.text {
                case "(", "[": depth += 1
                case ")", "]": depth -= 1
                case "+" where depth == 0:
                    terms.append([])
                    continue
                default: break
                }
            }
            terms[terms.count - 1].append(token)
        }

        return terms.compactMap { term in
            guard let first = term.first, let last = term.last else {
                return nil
            }
            if term.count == 1, first.kind == .string {
                return .literal(first.text)
            }
            let expression = String(decoding: source[first.range.lowerBound..<last.range.upperBound], as: UTF8.self)
            return .placeholder(expression)
        }
    }

    // MARK: - Building scripts

    private static func makeScript(kind: ExtractedScript.Kind, npc: String?, line: Int, lines: [[Segment]]) -> ExtractedScript? {
        guard !lines.isEmpty else {
            return nil
        }

        var text = ""
        var placeholders: [String] = []
        var hasText = false

        for (lineIndex, segments) in lines.enumerated() {
            if lineIndex > 0 {
                text += "\n"
            }
            for segment in segments {
                switch segment {
                case .literal(let literal):
                    text += literal
                    if !literal.allSatisfy(\.isWhitespace) {
                        hasText = true
                    }
                case .placeholder(let expression):
                    text += "{\(placeholders.count)}"
                    placeholders.append(expression)
                }
            }
        }

        guard hasText else {
            return nil
        }
        return ExtractedScript(kind: kind, npc: npc, line: line, text: text, placeholders: placeholders.isEmpty ? nil : placeholders)
    }

    /// Menu arguments may hold several options separated by `:`; empty options are hidden by the client.
    private static func makeOptions(npc: String?, line: Int, arguments: [[Segment]]) -> [ExtractedScript] {
        var options: [ExtractedScript] = []
        for argument in arguments {
            var current: [Segment] = []
            func finishOption() {
                if let option = makeScript(kind: .option, npc: npc, line: line, lines: [current]) {
                    options.append(option)
                }
                current.removeAll()
            }
            for (segmentIndex, segment) in argument.enumerated() {
                switch segment {
                case .placeholder(let expression):
                    // `select(.@menu$ + "Cancel")`: the variable holds a `:`-terminated list of options
                    // built elsewhere, so the literal after it is an option of its own.
                    if segmentIndex == 0, isMenuVariable(expression) {
                        continue
                    }
                    current.append(segment)
                case .literal(let literal):
                    let pieces = literal.split(separator: ":", omittingEmptySubsequences: false)
                    for (pieceIndex, piece) in pieces.enumerated() {
                        if pieceIndex > 0 {
                            finishOption()
                        }
                        current.append(.literal(String(piece)))
                    }
                }
            }
            finishOption()
        }
        return options
    }

    private static func isMenuVariable(_ expression: String) -> Bool {
        expression.lowercased().hasSuffix("menu$")
    }
}
