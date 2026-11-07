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

    /// Maximum number of alternative pages kept open at once.
    fileprivate static let maxVariants = 16

    init(source: String) {
        var tokenizer = ScriptTokenizer(source: source)
        let tokens = tokenizer.tokenize()

        let bytes = Array(source.utf8)
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

        var parser = self.parser
        let parsedScripts = parser.parseScripts()

        for script in parsedScripts {
            var walker = PageWalker(npc: script.npc, emit: append)
            walker.run(.block(script.statements))
            walker.finish()
        }

        // Stable by line so variants of one page keep their emission order.
        return scripts.enumerated()
            .sorted { ($0.element.line, $0.offset) < ($1.element.line, $1.offset) }
            .map(\.element)
    }
}

// MARK: - Page walker

/// Evaluates statements against the set of pages that may currently be open on the client.
private struct PageWalker {
    /// One possible content of the dialog box on one execution path.
    struct Variant: Equatable {
        var lines: [[Segment]] = []
        var line = 0
        var environment = TextEnvironment()
    }

    let npc: String?
    let emit: (ExtractedScript) -> Void

    /// Open pages, one per path. Empty means no path reaches here (after `close`, `end`, ...).
    private var open: [PageWalker.Variant] = [PageWalker.Variant()]

    init(npc: String?, emit: @escaping (ExtractedScript) -> Void) {
        self.npc = npc
        self.emit = emit
    }

    /// Runs `statement` and returns the variants that left it through `break`/`continue`.
    @discardableResult
    mutating func run(_ statement: Statement) -> [PageWalker.Variant] {
        switch statement {
        case .mes(let lines):
            if open.isEmpty {
                open = [PageWalker.Variant()]
            }
            for line in lines {
                var expanded: [Variant] = []
                for page in open {
                    for (segments, environment) in page.environment.expansions(for: line.expression) {
                        var variant = page
                        variant.environment = environment
                        if variant.lines.isEmpty {
                            variant.line = line.line
                        }
                        variant.lines.append(segments)
                        expanded.append(variant)
                    }
                }
                open = []
                merge(expanded)
            }
            return []
        case .transparent:
            return []
        case .assign(let reference, let expressions, let append):
            if open.isEmpty { open = [Variant()] }
            if expressions.count == 1, let expression = expressions.first {
                var expanded: [Variant] = []
                for page in open {
                    for (segments, environment) in page.environment.expansions(for: expression) {
                        var variant = page
                        variant.environment = environment
                        let terms: [TextExpression] = segments.map {
                            switch $0 {
                            case .literal(let value): return .literal(value)
                            case .placeholder(let source): return .unknown(source)
                            }
                        }
                        let value = TextExpression.concatenate(terms, source: expression.sourceText)
                        variant.environment.assign(reference, values: [value], append: append)
                        expanded.append(variant)
                    }
                }
                open = []
                merge(expanded)
            } else {
                for index in open.indices {
                    open[index].environment.assign(reference, values: expressions, append: append)
                }
            }
            return []
        case .forget(let names):
            for index in open.indices { open[index].environment.forget(names) }
            return []
        case .forgetAll:
            for index in open.indices { open[index].environment = TextEnvironment() }
            return []
        case .options(let arguments, let line):
            if open.isEmpty { open = [Variant()] }
            for page in open {
                makeOptions(line: line, arguments: arguments, environment: page.environment).forEach(emit)
            }
            return []
        case .newPage:
            flush()
            open = union(open.map { Variant(environment: $0.environment) })
            if open.isEmpty { open = [Variant()] }
            return []
        case .label:
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
            var exits: [PageWalker.Variant] = []
            for statement in statements {
                exits += run(statement)
            }
            return exits
        case .branch(let alternatives, let otherwise):
            let before = open
            var after: [PageWalker.Variant] = []
            var exits: [PageWalker.Variant] = []
            for alternative in alternatives {
                open = before
                exits += run(alternative)
                after = union(after, open)
            }
            if let otherwise {
                open = before
                exits += run(otherwise)
                after = union(after, open)
            } else {
                after = union(after, before)
            }
            open = []
            merge(after)
            return exits
        case .switch(let cases, let hasDefault):
            // Execution jumps to the matching case and falls through into the following
            // cases until a `break`, so each case starts from the jump state plus whatever
            // fell out of the previous case.
            let before = open
            var after: [PageWalker.Variant] = hasDefault ? [] : before
            var fallen: [PageWalker.Variant] = []
            for body in cases {
                open = union(before, fallen)
                after = union(after, run(body))
                fallen = open
            }
            open = []
            merge(union(after, fallen))
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

    /// Menu arguments may hold several options separated by `:`; empty options are hidden by the client.
    private func makeOptions(line: Int, arguments: [TextExpression], environment: TextEnvironment) -> [ExtractedScript] {
        var options: [ExtractedScript] = []
        for argument in arguments.flatMap({ $0.variants(in: environment) }) {
            var current: [Segment] = []
            func finishOption() {
                if let option = ExtractedScript(kind: .option, npc: npc, line: line, lines: [current]) {
                    options.append(option)
                }
                current.removeAll()
            }
            for segment in argument {
                switch segment {
                case .placeholder:
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

    private mutating func merge(_ variants: [PageWalker.Variant]) {
        open = union(open, variants)
        if open.count > ScriptExtractor.maxVariants {
            flush()
            open = [Variant(environment: .joined(open.map(\.environment)))]
        }
    }

    private func union(_ lists: [PageWalker.Variant]...) -> [PageWalker.Variant] {
        var result: [PageWalker.Variant] = []
        for list in lists {
            for variant in list where !result.contains(variant) {
                result.append(variant)
            }
        }
        return result
    }

    private func flush() {
        for variant in open where !variant.lines.isEmpty {
            if let script = ExtractedScript(kind: .message, npc: npc, line: variant.line, lines: variant.lines) {
                emit(script)
            }
        }
    }
}
