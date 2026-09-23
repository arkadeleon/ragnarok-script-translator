//
//  ScriptExtractor.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/21.
//

/// Collects dialog pages and menu options from one NPC file.
///
/// Pages are what the client sees between two `next`/`close` calls. Because `mes` lines are often
/// spread over `if`/`switch` branches, the extractor walks every path through those branches and
/// emits a page per path, so runtime pages can be matched as a whole. Paths are capped per page;
/// past the cap the pending text is emitted as is and matching falls back to line chunks.
struct ScriptExtractor {
    private let parser: ScriptParser
    private let tokens: [Token]

    /// Maximum number of alternative pages kept open at once.
    fileprivate static let maxVariants = 16

    init(source: String) {
        let bytes = Array(source.utf8)
        tokens = ScriptTokenizer.tokenize(source)
        parser = ScriptParser(source: bytes, tokens: tokens)
    }

    func extract() -> [ExtractedScript] {
        var scripts: [ExtractedScript] = []
        var emitted: Set<[String]> = []

        // The same page can be reached on several paths and flushed by each; keep it once per source location.
        func append(_ script: ExtractedScript) {
            let key = [script.kind.rawValue, String(script.line), script.text] + (script.placeholders ?? [])
            if emitted.insert(key).inserted {
                scripts.append(script)
            }
        }

        for script in ScriptParser.parse(source: parser.source, tokens: tokens) {
            var walker = PageWalker(npc: script.npc, emit: append)
            walker.run(.block(script.statements))
            walker.finish()
        }

        extractOptions(into: append)

        // Stable by line so variants of one page keep their emission order.
        return scripts.enumerated()
            .sorted { ($0.element.line, $0.offset) < ($1.element.line, $1.offset) }
            .map(\.element)
    }

    // MARK: - Options

    /// `select`/`prompt`/`menu` can sit inside any expression, so options are collected by a flat scan.
    private func extractOptions(into append: (ExtractedScript) -> Void) {
        var npc: String?
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if case .header(let name) = token.kind {
                npc = name
                index += 1
                continue
            }
            guard token.kind == .identifier else {
                index += 1
                continue
            }

            switch token.text.lowercased() {
            case "select", "prompt":
                guard index + 1 < tokens.count, tokens[index + 1].kind == .punctuation, tokens[index + 1].text == "(" else {
                    index += 1
                    continue
                }
                let (arguments, end) = parser.parseArguments(from: index + 2, until: ")")
                Self.makeOptions(npc: npc, line: token.line, arguments: arguments).forEach(append)
                index = end

            case "menu":
                let (arguments, end) = parser.parseArguments(from: index + 1, until: ";")
                // `menu "text",L_label,"text",L_label,...`: every other argument is a label.
                let texts = arguments.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
                Self.makeOptions(npc: npc, line: token.line, arguments: texts).forEach(append)
                index = end

            default:
                index += 1
            }
        }
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

    // MARK: - Building scripts

    static func makeScript(kind: ExtractedScript.Kind, npc: String?, line: Int, lines: [[Segment]]) -> ExtractedScript? {
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
}

// MARK: - Page walker

/// Evaluates statements against the set of pages that may currently be open on the client.
private struct PageWalker {
    /// One possible content of the dialog box on one execution path.
    struct Variant: Equatable {
        var lines: [[Segment]] = []
        var line = 0
    }

    let npc: String?
    let emit: (ExtractedScript) -> Void

    /// Open pages, one per path. Empty means no path reaches here (after `close`, `end`, ...).
    private var open: [Variant] = [Variant()]

    init(npc: String?, emit: @escaping (ExtractedScript) -> Void) {
        self.npc = npc
        self.emit = emit
    }

    /// Runs `statement` and returns the variants that left it through `break`/`continue`.
    @discardableResult
    mutating func run(_ statement: Statement) -> [Variant] {
        switch statement {
        case .mes(let lines):
            if open.isEmpty {
                open = [Variant()]
            }
            for index in open.indices {
                if open[index].lines.isEmpty, let first = lines.first {
                    open[index].line = first.line
                }
                open[index].lines.append(contentsOf: lines.map(\.segments))
            }
            return []

        case .transparent:
            return []

        case .newPage, .label:
            flush()
            open = [Variant()]
            return []

        case .terminate:
            flush()
            open = []
            return []

        case .exit:
            let exits = open
            open = []
            return exits

        case .block(let statements):
            var exits: [Variant] = []
            for statement in statements {
                exits += run(statement)
            }
            return exits

        case .branch(let alternatives, let otherwise):
            let before = open
            var after: [Variant] = []
            var exits: [Variant] = []
            for alternative in alternatives {
                open = before
                exits += run(alternative)
                after = Self.union(after, open)
            }
            if let otherwise {
                open = before
                exits += run(otherwise)
                after = Self.union(after, open)
            } else {
                after = Self.union(after, before)
            }
            open = []
            merge(after)
            return exits

        case .switch(let cases, let hasDefault):
            // Execution jumps to the matching case and falls through into the following
            // cases until a `break`, so each case starts from the jump state plus whatever
            // fell out of the previous case.
            let before = open
            var after: [Variant] = hasDefault ? [] : before
            var fallen: [Variant] = []
            for body in cases {
                open = Self.union(before, fallen)
                after = Self.union(after, run(body))
                fallen = open
            }
            open = []
            merge(Self.union(after, fallen))
            return []

        case .loop(let body):
            let before = open
            let exits = run(body)
            merge(before)
            merge(exits)
            return []
        }
    }

    mutating func finish() {
        flush()
        open = []
    }

    // MARK: - Private

    private mutating func merge(_ variants: [Variant]) {
        open = Self.union(open, variants)
        if open.count > ScriptExtractor.maxVariants {
            flush()
            open = [Variant()]
        }
    }

    private static func union(_ lists: [Variant]...) -> [Variant] {
        var result: [Variant] = []
        for list in lists {
            for variant in list where !result.contains(variant) {
                result.append(variant)
            }
        }
        return result
    }

    private func flush() {
        for variant in open where !variant.lines.isEmpty {
            if let script = ScriptExtractor.makeScript(kind: .message, npc: npc, line: variant.line, lines: variant.lines) {
                emit(script)
            }
        }
    }
}
