//
//  ScriptParser.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/21.
//

/// The subset of rAthena script structure that affects which `mes` lines end up on the same page.
indirect enum Statement {
    /// `mes "..."[, "..."]`
    case mes([DialogLine])
    /// A statement that does not touch the dialog box (`set`, `getitem`, ...).
    case transparent
    /// Ends the current page but lets the script continue on a fresh one (`next`, `clear`, `select`, ...).
    case newPage
    /// Ends the current page and the current path (`close`, `end`, `return`, `goto`).
    case terminate
    /// `break` / `continue`: leaves the enclosing `switch` or loop.
    case exit
    /// A jump target (`OnInit:`, `L_Label:`); anything may arrive here, so the page starts over.
    case label
    case block([Statement])
    case branch(then: Statement, else: Statement?)
    case `switch`(cases: [Statement], hasDefault: Bool)
    case loop(Statement)
}

/// One script body: the statements between a header and its closing brace.
struct ParsedScript {
    var npc: String?
    var statements: [Statement]
}

/// Recursive-descent parser over the token stream. Expressions are skipped, not parsed; only
/// `mes` arguments are decomposed into segments.
struct ScriptParser {
    let source: [UInt8]
    private let tokens: [Token]
    private var index = 0

    /// Commands that clear the dialog box or hand control elsewhere, and so end a page.
    private static let newPageCommands: Set<String> = ["next", "clear", "close2", "callfunc", "callsub", "select", "prompt", "menu", "input"]
    private static let terminateCommands: Set<String> = ["close", "close3", "end", "return", "goto"]
    /// Commands taking a menu string; a statement mentioning them ends the page even mid-expression.
    private static let menuCommands: Set<String> = ["select", "prompt", "menu", "input"]

    init(source: [UInt8], tokens: [Token]) {
        self.source = source
        self.tokens = tokens
    }

    static func parse(source: [UInt8], tokens: [Token]) -> [ParsedScript] {
        var parser = ScriptParser(source: source, tokens: tokens)
        return parser.parseScripts()
    }

    private mutating func parseScripts() -> [ParsedScript] {
        var scripts: [ParsedScript] = []
        while index < tokens.count {
            guard case .header(let npc) = tokens[index].kind else {
                // Stray tokens outside a body; skip.
                index += 1
                continue
            }
            index += 1
            let statements = parseStatements()
            if index < tokens.count, isPunctuation("}") {
                index += 1
            }
            scripts.append(ParsedScript(npc: npc, statements: statements))
        }
        return scripts
    }

    /// Parses until an unmatched `}` or the next header.
    private mutating func parseStatements() -> [Statement] {
        var statements: [Statement] = []
        while index < tokens.count {
            if case .header = tokens[index].kind { break }
            if isPunctuation("}") { break }
            if let statement = parseStatement() {
                statements.append(statement)
            }
        }
        return statements
    }

    private mutating func parseStatement() -> Statement? {
        guard index < tokens.count else { return nil }
        let token = tokens[index]

        if case .header = token.kind { return nil }

        if token.kind == .punctuation {
            switch token.text {
            case "{":
                index += 1
                let statements = parseStatements()
                if isPunctuation("}") { index += 1 }
                return .block(statements)
            case ";":
                index += 1
                return .transparent
            default:
                return parseSimpleStatement()
            }
        }

        guard token.kind == .identifier else {
            return parseSimpleStatement()
        }

        switch token.text.lowercased() {
        case "if":
            index += 1
            skipParenthesized()
            let then = parseStatement() ?? .transparent
            var otherwise: Statement?
            if index < tokens.count, tokens[index].kind == .identifier, tokens[index].text.lowercased() == "else" {
                index += 1
                otherwise = parseStatement() ?? .transparent
            }
            return .branch(then: then, else: otherwise)

        case "else":
            // Dangling else (e.g. after a `;` we did not model); treat its body as unconditional.
            index += 1
            return parseStatement()

        case "switch":
            index += 1
            skipParenthesized()
            return parseSwitchBody()

        case "while", "for":
            index += 1
            skipParenthesized()
            return .loop(parseStatement() ?? .transparent)

        case "do":
            index += 1
            let body = parseStatement() ?? .transparent
            if index < tokens.count, tokens[index].kind == .identifier, tokens[index].text.lowercased() == "while" {
                index += 1
                skipParenthesized()
                if isPunctuation(";") { index += 1 }
            }
            return .loop(body)

        case "case", "default":
            // Outside a switch body we parsed; skip to the colon.
            while index < tokens.count, !isPunctuation(":") { index += 1 }
            if index < tokens.count { index += 1 }
            return .label

        case "mes":
            let (arguments, end) = parseArguments(from: index + 1, until: ";")
            index = end
            let lines = arguments.map { DialogLine(segments: $0, line: token.line) }
            return .mes(lines)

        default:
            if index + 1 < tokens.count, tokens[index + 1].kind == .punctuation, tokens[index + 1].text == ":" {
                index += 2
                return .label
            }
            return parseSimpleStatement()
        }
    }

    private mutating func parseSwitchBody() -> Statement {
        guard isPunctuation("{") else {
            return parseStatement() ?? .transparent
        }
        index += 1

        var cases: [Statement] = []
        var current: [Statement] = []
        var hasDefault = false
        var inCase = false
        // rAthena compiles `switch` to a plain assignment and jumps only at `case` labels, so
        // statements before the first `case` run unconditionally.
        var prelude: [Statement] = []

        func finishCase() {
            if inCase {
                cases.append(.block(current))
            } else {
                prelude = current
            }
            current.removeAll()
        }

        while index < tokens.count {
            if case .header = tokens[index].kind { break }
            if isPunctuation("}") {
                index += 1
                break
            }
            let token = tokens[index]
            if token.kind == .identifier, ["case", "default"].contains(token.text.lowercased()) {
                finishCase()
                inCase = true
                hasDefault = hasDefault || token.text.lowercased() == "default"
                while index < tokens.count, !isPunctuation(":") { index += 1 }
                if index < tokens.count { index += 1 }
                continue
            }
            if let statement = parseStatement() {
                current.append(statement)
            }
        }
        finishCase()
        let switchStatement = Statement.switch(cases: cases, hasDefault: hasDefault)
        return prelude.isEmpty ? switchStatement : .block(prelude + [switchStatement])
    }

    /// Consumes tokens up to and including the next `;` at nesting depth 0 and classifies the statement.
    private mutating func parseSimpleStatement() -> Statement {
        var depth = 0
        var command: String?
        var mentionsMenu = false

        while index < tokens.count {
            let token = tokens[index]
            if case .header = token.kind { break }
            if token.kind == .punctuation {
                switch token.text {
                case "(", "[": depth += 1
                case ")", "]": depth -= 1
                case "{", "}":
                    if depth <= 0 { return classify(command, mentionsMenu) }
                case ";":
                    if depth <= 0 {
                        index += 1
                        return classify(command, mentionsMenu)
                    }
                default: break
                }
            } else if token.kind == .identifier {
                let name = token.text.lowercased()
                if command == nil { command = name }
                if Self.menuCommands.contains(name) { mentionsMenu = true }
            }
            index += 1
        }
        return classify(command, mentionsMenu)
    }

    private func classify(_ command: String?, _ mentionsMenu: Bool) -> Statement {
        if let command {
            if Self.terminateCommands.contains(command) { return .terminate }
            if Self.newPageCommands.contains(command) { return .newPage }
            if command == "break" || command == "continue" { return .exit }
            // Script functions (`F_Foo(...)`) are called directly and may show dialog themselves.
            if command.hasPrefix("f_") { return .newPage }
        }
        return mentionsMenu ? .newPage : .transparent
    }

    private mutating func skipParenthesized() {
        guard isPunctuation("(") else { return }
        var depth = 0
        while index < tokens.count {
            if case .header = tokens[index].kind { return }
            if tokens[index].kind == .punctuation {
                if tokens[index].text == "(" { depth += 1 }
                if tokens[index].text == ")" {
                    depth -= 1
                    if depth == 0 {
                        index += 1
                        return
                    }
                }
            }
            index += 1
        }
    }

    private func isPunctuation(_ text: String) -> Bool {
        index < tokens.count && tokens[index].kind == .punctuation && tokens[index].text == text
    }

    // MARK: - Arguments

    /// Reads comma-separated arguments up to `terminator` at nesting depth 0.
    /// Returns the arguments as segments and the index just past the terminator.
    func parseArguments(from start: Int, until terminator: String) -> (arguments: [[Segment]], end: Int) {
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
                break
            }
            if token.kind == .punctuation {
                switch token.text {
                case "(", "[":
                    depth += 1
                case ")", "]":
                    if depth == 0 {
                        finishArgument()
                        return (arguments, terminator == ")" ? index + 1 : index)
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
}
