//
//  ScriptParser.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/21.
//

/// One `mes` argument: a single line of dialog.
struct DialogLine {
    var expression: TextExpression
    var line: Int
}

/// The subset of rAthena script structure that affects which `mes` lines end up on the same page.
indirect enum Statement {
    /// `mes "..."[, "..."]`
    case mes([DialogLine])

    /// A statement that does not touch the dialog box (`set`, `getitem`, ...).
    case transparent

    case assign(TextReference, values: [TextExpression], append: Bool)
    case forget([String])
    case forgetAll
    case options([TextExpression], line: Int)

    /// Ends the current page but lets the script continue on a fresh one (`next`, `clear`, `select`, ...).
    case newPage

    /// Ends the current page and the current path (`close`, `end`, `return`, `goto`).
    case terminate

    /// `break` / `continue`: leaves the enclosing `switch` or loop.
    case exit

    /// A jump target (`OnInit:`, `L_Label:`); anything may arrive here, so the page starts over.
    case label

    case block([Statement])

    /// `if ... else if ... else ...`: one alternative runs, or none when there is no `else`.
    /// Kept flat rather than nested so a 300-deep `else if` chain does not recurse 300 deep.
    case branch(alternatives: [Statement], otherwise: Statement?)

    case `switch`(cases: [Statement], hasDefault: Bool)

    case loop(Statement)
}

/// One script body: the statements between a header and its closing brace.
struct ParsedScript {
    var npc: String?
    var statements: [Statement]
}

/// Parses dialog-affecting statements and delegates text expressions to ExpressionParser.
struct ScriptParser {
    let source: [UInt8]
    let tokens: [Token]

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

    mutating func parseScripts() -> [ParsedScript] {
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
            let script = ParsedScript(npc: npc, statements: statements)
            scripts.append(script)
        }
        return scripts
    }

    /// Parses until an unmatched `}` or the next header.
    private mutating func parseStatements() -> [Statement] {
        var statements: [Statement] = []
        while index < tokens.count {
            if case .header = tokens[index].kind {
                break
            }
            if isPunctuation("}") {
                break
            }
            if let statement = parseStatement() {
                statements.append(statement)
            }
        }
        return statements
    }

    private mutating func parseStatement() -> Statement? {
        guard index < tokens.count else {
            return nil
        }
        let token = tokens[index]

        if case .header = token.kind {
            return nil
        }

        if token.kind == .punctuation {
            switch token.text {
            case "{":
                index += 1
                let statements = parseStatements()
                if isPunctuation("}") {
                    index += 1
                }
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
            var conditions: [Statement] = []
            var alternatives: [Statement] = []
            var otherwise: Statement?
            while true {
                index += 1 // `if`
                conditions += skipParenthesized()
                alternatives.append(parseStatement() ?? .transparent)
                guard index < tokens.count, tokens[index].kind == .identifier, tokens[index].text.lowercased() == "else" else {
                    break
                }
                index += 1 // `else`
                if index < tokens.count, tokens[index].kind == .identifier, tokens[index].text.lowercased() == "if" {
                    continue
                }
                otherwise = parseStatement() ?? .transparent
                break
            }
            return .block(conditions + [.branch(alternatives: alternatives, otherwise: otherwise)])
        case "else":
            // Dangling else (e.g. after a `;` we did not model); treat its body as unconditional.
            index += 1
            return parseStatement()
        case "switch":
            index += 1
            let options = skipParenthesized()
            return .block(options + [parseSwitchBody()])
        case "while", "for":
            index += 1
            let options = skipParenthesized()
            return .block(options + [.loop(parseStatement() ?? .transparent)])
        case "do":
            index += 1
            let body = parseStatement() ?? .transparent
            var condition: [Statement] = []
            if index < tokens.count, tokens[index].kind == .identifier, tokens[index].text.lowercased() == "while" {
                index += 1
                condition = skipParenthesized()
                if isPunctuation(";") {
                    index += 1
                }
            }
            return .block([.loop(body)] + condition)
        case "case", "default":
            // Outside a switch body we parsed; skip to the colon.
            while index < tokens.count, !isPunctuation(":") {
                index += 1
            }
            if index < tokens.count {
                index += 1
            }
            return .label
        case "mes":
            let start = index + 1
            let (arguments, end) = parseArguments(from: start, until: ";")
            index = end
            let lines = arguments.map { DialogLine(expression: $0, line: token.line) }
            let invalidation: [Statement] = containsScriptCall(from: start, to: end) ? [.forgetAll] : []
            return .block(options(from: start, to: end) + invalidation + [.mes(lines)])
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
            if case .header = tokens[index].kind {
                break
            }
            if isPunctuation("}") {
                index += 1
                break
            }
            let token = tokens[index]
            if token.kind == .identifier, ["case", "default"].contains(token.text.lowercased()) {
                finishCase()
                inCase = true
                hasDefault = hasDefault || token.text.lowercased() == "default"
                while index < tokens.count, !isPunctuation(":") {
                    index += 1
                }
                if index < tokens.count {
                    index += 1
                }
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
        let start = index
        var depth = 0
        var command: String?
        var mentionsMenu = false

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
                    depth -= 1
                case "{", "}":
                    if depth <= 0 {
                        return simpleStatement(from: start, to: index, command: command, mentionsMenu: mentionsMenu)
                    }
                case ";":
                    if depth <= 0 {
                        index += 1
                        return simpleStatement(from: start, to: index, command: command, mentionsMenu: mentionsMenu)
                    }
                default:
                    break
                }
            } else if token.kind == .identifier {
                let name = token.text.lowercased()
                if command == nil {
                    command = name
                }
                if Self.menuCommands.contains(name) {
                    mentionsMenu = true
                }
            }
            index += 1
        }
        return simpleStatement(from: start, to: index, command: command, mentionsMenu: mentionsMenu)
    }

    private func simpleStatement(from start: Int, to end: Int, command: String?, mentionsMenu: Bool) -> Statement {
        var body = Array(tokens[start..<end])
        if body.last?.text == ";" { body.removeLast() }
        var statements = options(from: start, to: end)
        let expressionParser = ExpressionParser(source: source)
        let rawArguments: [TextExpression]
        if ["set", "setarray", "input", "cleararray", "deletearray", "copyarray", "explode", "query_sql", "query_logsql"].contains(command ?? "") {
            rawArguments = parseArguments(from: start + 1, until: ";").arguments
        } else {
            rawArguments = []
        }
        if command == "set" || command == "setarray" {
            if let first = rawArguments.first, case .reference(let target) = first, rawArguments.count >= 2 {
                let values = command == "setarray" ? Array(rawArguments.dropFirst()) : [rawArguments[1]]
                statements.append(.assign(target, values: values, append: false))
            }
        } else if body.count >= 3, body[0].kind == .identifier {
            // Assignments are statement-level only. Do not confuse == or nested assignments
            // in expressions with an update of this variable.
            var nesting = 0
            for position in body.indices {
                let token = body[position]
                guard token.kind == .punctuation else { continue }
                if token.text == "[" || token.text == "(" { nesting += 1 }
                if token.text == "]" || token.text == ")" { nesting -= 1 }
                if token.text == "=", nesting == 0 {
                    let compound = position > 0 && body[position - 1].kind == .punctuation && "+-*/%&|^".contains(body[position - 1].text)
                    let appending = compound && body[position - 1].text == "+"
                    let targetEnd = compound ? position - 1 : position
                    let target = expressionParser.parse(Array(body[..<targetEnd]))
                    if case .reference(let reference) = target {
                        let value = expressionParser.parse(Array(body[(position + 1)...]))
                        if compound && !appending {
                            statements.append(.forget([reference.name]))
                        } else {
                            statements.append(.assign(reference, values: [value], append: appending))
                        }
                    }
                    break
                }
            }
        }
        if body.count >= 3 {
            let prefix = body[0].text == body[1].text && ["+", "-"].contains(body[0].text)
            let suffix = body[body.count - 1].text == body[body.count - 2].text && ["+", "-"].contains(body[body.count - 1].text)
            let targetTokens = prefix ? Array(body.dropFirst(2)) : suffix ? Array(body.dropLast(2)) : []
            if case .reference(let target) = expressionParser.parse(targetTokens) {
                statements.append(.forget([target.name]))
            }
        }
        // Commands writing external or unmodelled values must invalidate earlier constants.
        let destinations = ["input", "cleararray", "deletearray", "copyarray", "explode"]
        if destinations.contains(command ?? ""), let first = rawArguments.first, case .reference(let target) = first {
            statements.append(.forget([target.name]))
        }
        if command == "query_sql" || command == "query_logsql" {
            statements.append(.forget(rawArguments.dropFirst().compactMap {
                if case .reference(let target) = $0 { return target.name }
                return nil
            }))
        }
        if containsScriptCall(from: start, to: end) || command == "setd" {
            // Calls may mutate variables before their result is assigned.
            statements.insert(.forgetAll, at: 0)
        }
        statements.append(classify(command, mentionsMenu))
        return .block(statements)
    }

    /// Find menu calls even inside assignments and conditions. Evaluation happens later,
    /// against the environment of the path reaching the enclosing statement.
    private func options(from start: Int, to end: Int) -> [Statement] {
        var statements: [Statement] = []
        var cursor = start
        while cursor < end {
            let token = tokens[cursor]
            guard token.kind == .identifier else { cursor += 1; continue }
            let name = token.text.lowercased()
            if (name == "select" || name == "prompt"), cursor + 1 < end, tokens[cursor + 1].text == "(" {
                let result = parseArguments(from: cursor + 2, until: ")")
                statements.append(.options(result.arguments, line: token.line))
                cursor = max(cursor + 1, result.end)
            } else if name == "menu" {
                let result = parseArguments(from: cursor + 1, until: ";")
                statements.append(.options(result.arguments.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element), line: token.line))
                cursor = max(cursor + 1, result.end)
            } else {
                cursor += 1
            }
        }
        return statements
    }

    private func classify(_ command: String?, _ mentionsMenu: Bool) -> Statement {
        if let command {
            if Self.terminateCommands.contains(command) {
                return .terminate
            }
            if Self.newPageCommands.contains(command) {
                return .newPage
            }
            if command == "break" || command == "continue" {
                return .exit
            }
            // Script functions (`F_Foo(...)`) are called directly and may show dialog themselves.
            if command.hasPrefix("f_") {
                return .newPage
            }
        }
        return mentionsMenu ? .newPage : .transparent
    }

    private mutating func skipParenthesized() -> [Statement] {
        let start = index
        guard isPunctuation("(") else {
            return []
        }
        var depth = 0
        while index < tokens.count {
            if case .header = tokens[index].kind {
                return []
            }
            if tokens[index].kind == .punctuation {
                if tokens[index].text == "(" {
                    depth += 1
                }
                if tokens[index].text == ")" {
                    depth -= 1
                    if depth == 0 {
                        index += 1
                        return options(from: start, to: index) + conditionWrites(from: start, to: index)
                    }
                }
            }
            index += 1
        }
        return options(from: start, to: index) + conditionWrites(from: start, to: index)
    }

    private func conditionWrites(from start: Int, to end: Int) -> [Statement] {
        var names: [String] = []
        for position in start..<end where tokens[position].kind == .identifier {
            let next = position + 1
            guard next + 1 < end, tokens[next].kind == .punctuation else { continue }
            let operation = tokens[next].text
            let following = tokens[next + 1].text
            if (operation == "=" && following != "=") ||
               (["+", "-", "*", "/", "%", "&", "|", "^"].contains(operation) && following == "=") ||
               (["+", "-"].contains(operation) && following == operation) {
                names.append(tokens[position].text)
            }
        }
        if containsScriptCall(from: start, to: end) { return [.forgetAll] }
        return names.isEmpty ? [] : [.forget(names)]
    }

    private func containsScriptCall(from start: Int, to end: Int) -> Bool {
        tokens[start..<end].contains { token in
            guard token.kind == .identifier else { return false }
            let name = token.text.lowercased()
            return name == "callsub" || name == "callfunc" || name.hasPrefix("f_")
        }
    }

    private func isPunctuation(_ text: String) -> Bool {
        index < tokens.count && tokens[index].kind == .punctuation && tokens[index].text == text
    }

    // MARK: - Arguments

    /// Reads comma-separated arguments up to `terminator` at nesting depth 0.
    /// Returns the arguments as expressions and the index just past the terminator.
    func parseArguments(from start: Int, until terminator: String) -> (arguments: [TextExpression], end: Int) {
        var arguments: [TextExpression] = []
        var current: [Token] = []
        var depth = 0
        var index = start

        func finishArgument() {
            if !current.isEmpty {
                arguments.append(ExpressionParser(source: source).parse(current))
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

}
