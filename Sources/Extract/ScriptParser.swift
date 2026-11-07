//
//  ScriptParser.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/21.
//

struct DialogLine {
    var expression: TextExpression
    var line: Int
}

struct ConditionalArm {
    var condition: TextExpression
    var body: Statement
}

struct SwitchArm {
    var value: TextExpression? // nil is default
    var body: Statement
}

indirect enum Statement {
    case mes([DialogLine])
    case transparent
    case assign(TextReference, values: [TextExpression], append: Bool)
    case forget([String])
    case forgetAll
    case assignArgument(TextExpression, TextExpression)
    case invalidateArgument(TextExpression)
    case evaluate(TextExpression, line: Int)
    case menu([(TextExpression, String)], line: Int)
    case newPage
    case terminate
    case returnValue(TextExpression?)
    case jump(String)
    case breakLoop
    case continueLoop
    case label(String)
    case function(String, Statement)
    case block([Statement])
    case branch([ConditionalArm], otherwise: Statement?)
    case switchValue(TextExpression, [SwitchArm])
    case loop(initial: Statement, condition: TextExpression?, step: Statement, body: Statement, atLeastOnce: Bool)
}

struct ParsedScript {
    var npc: String?
    var name: String
    var isFunction: Bool
    var statements: [Statement]
}

/// Keeps conditions, loop updates and calls intact for the control-flow interpreter.
struct ScriptParser {
    let source: [UInt8]
    let tokens: [Token]
    private var index = 0

    init(source: [UInt8], tokens: [Token]) {
        self.source = source
        self.tokens = tokens
    }

    mutating func parseScripts() -> [ParsedScript] {
        var scripts: [ParsedScript] = []
        while index < tokens.count {
            guard case .header(let npc, let name, let isFunction) = tokens[index].kind else { index += 1; continue }
            index += 1
            let body = statements()
            if punctuation("}") { index += 1 }
            scripts.append(.init(npc: npc, name: name, isFunction: isFunction, statements: body))
        }
        return scripts
    }

    private mutating func statements() -> [Statement] {
        var result: [Statement] = []
        while index < tokens.count, !punctuation("}") {
            if case .header = tokens[index].kind { break }
            let before = index
            result.append(statement())
            if index == before { index += 1 } // malformed input must still make progress
        }
        return result
    }

    private mutating func statement() -> Statement {
        guard index < tokens.count else { return .transparent }
        if punctuation("{") {
            index += 1
            let body = statements()
            if punctuation("}") { index += 1 }
            return .block(body)
        }
        let token = tokens[index]
        if token.kind == .identifier {
            let name = token.text.lowercased()
            if index + 1 < tokens.count, tokens[index + 1].text == ":" {
                index += 2
                return .label(token.text)
            }
            switch name {
            case "if":
                var arms: [ConditionalArm] = []
                var otherwise: Statement?
                repeat {
                    index += 1
                    let condition = expression(conditionTokens())
                    arms.append(.init(condition: condition, body: statement()))
                    guard identifier("else") else { break }
                    index += 1
                    if !identifier("if") { otherwise = statement(); break }
                } while index < tokens.count
                return .branch(arms, otherwise: otherwise)
            case "switch":
                index += 1
                let value = expression(conditionTokens())
                guard punctuation("{") else { return statement() }
                index += 1
                var arms: [SwitchArm] = []
                var prelude: [Statement] = []
                while index < tokens.count, !punctuation("}") {
                    if identifier("case") || identifier("default") {
                        let isDefault = identifier("default")
                        index += 1
                        let value = read(until: ":")
                        arms.append(.init(value: isDefault ? nil : expression(value), body: .block([])))
                    } else {
                        let body = statement()
                        if let last = arms.indices.last {
                            if case .block(let previous) = arms[last].body { arms[last].body = .block(previous + [body]) }
                        } else { prelude.append(body) }
                    }
                }
                if punctuation("}") { index += 1 }
                return .block(prelude + [.switchValue(value, arms)])
            case "for", "while":
                index += 1
                let header = parenthesized()
                let parts = split(header, on: ";")
                let initial = name == "for" ? simple(parts.first ?? [], line: token.line) : .transparent
                let condition = name == "for" ? (parts.count > 1 ? parts[1] : []) : header
                let step = name == "for" && parts.count > 2 ? simple(parts[2], line: token.line) : .transparent
                return .loop(initial: initial, condition: condition.isEmpty ? nil : expression(condition), step: step, body: statement(), atLeastOnce: false)
            case "do":
                index += 1
                let body = statement()
                var condition: TextExpression?
                if identifier("while") { index += 1; condition = expression(conditionTokens()) }
                if punctuation(";") { index += 1 }
                return .loop(initial: .transparent, condition: condition, step: .transparent, body: body, atLeastOnce: true)
            case "function":
                index += 1
                guard index < tokens.count else { return .transparent }
                let function = tokens[index].text
                index += 1
                if punctuation(";") { index += 1; return .transparent }
                return .function(function, statement())
            default: break
            }
        }
        return simple(read(until: ";"), line: token.line)
    }

    private func simple(_ body: [Token], line: Int) -> Statement {
        guard let first = body.first else { return .transparent }
        let name = first.text.lowercased()
        let rest = Array(body.dropFirst())
        let args = split(rest, on: ",").filter { !$0.isEmpty }.map(expression)
        switch name {
        case "mes": return .mes(args.map { .init(expression: $0, line: line) })
        case "next", "clear", "close2": return .newPage
        case "close", "close3", "end": return .terminate
        case "return": return .returnValue(rest.isEmpty ? nil : expression(rest))
        case "goto": return .jump(rest.first?.text ?? "")
        case "break": return .breakLoop
        case "continue": return .continueLoop
        case "menu":
            var entries: [(TextExpression, String)] = []
            for offset in stride(from: 0, to: max(0, args.count - 1), by: 2) {
                entries.append((args[offset], args[offset + 1].sourceText))
            }
            return .menu(entries, line: line)
        case "set", "setarray":
            if args.count >= 2, case .reference(let target) = args[0] {
                return .assign(target, values: name == "setarray" ? Array(args.dropFirst()) : [args[1]], append: false)
            }
            if args.count >= 2, case .call(let function, let parameters, _, _) = args[0], function.lowercased() == "getarg", let position = parameters.first {
                return name == "set" ? .assignArgument(position, args[1]) : .invalidateArgument(position)
            }
        case "callfunc", "callsub":
            // Parenthesized calls already include the complete argument list.
            if rest.first?.text == "(" { return .evaluate(expression(body), line: line) }
            return .evaluate(.call(name, args, source: spelling(body), line: line), line: line)
        case "input", "cleararray", "deletearray", "copyarray", "explode":
            if let first = args.first, case .reference(let target) = first { return .forget([target.name]) }
        case "query_sql", "query_logsql":
            return .forget(args.dropFirst().compactMap { if case .reference(let target) = $0 { return target.name }; return nil })
        case "setd": return .forgetAll
        default: break
        }
        var depth = 0
        for position in body.indices {
            let token = body[position]
            guard token.kind == .punctuation else { continue }
            if token.text == "[" || token.text == "(" { depth += 1 }
            if token.text == "]" || token.text == ")" { depth -= 1 }
            if token.text == "=", depth == 0, position + 1 < body.count, body[position + 1].text != "=" {
                let compound = position > 0 && body[position - 1].kind == .punctuation && "+-*/%&|^".contains(body[position - 1].text)
                let end = compound ? position - 1 : position
                if case .reference(let target) = expression(Array(body[..<end])) {
                    let value = expression(Array(body[(position + 1)...]))
                    if compound && body[position - 1].text != "+" {
                        return .assign(target, values: [.operation(body[position - 1].text, [.reference(target), value], source: spelling(body))], append: false)
                    }
                    return .assign(target, values: [value], append: compound)
                }
                break
            }
        }
        if body.count >= 3 {
            let prefix = body[0].text == body[1].text && ["+", "-"].contains(body[0].text)
            let suffix = body[body.count - 1].text == body[body.count - 2].text && ["+", "-"].contains(body[body.count - 1].text)
            let target = prefix ? Array(body.dropFirst(2)) : suffix ? Array(body.dropLast(2)) : []
            if case .reference(let reference) = expression(target) {
                let delta = (prefix ? body[0].text : body.last!.text) == "+" ? 1 : -1
                return .assign(reference, values: [.operation("+", [.reference(reference), .number(delta, source: String(delta))], source: spelling(body))], append: false)
            }
        }
        // Calls nested in ordinary commands may contain select/prompt or script functions.
        if first.kind == .identifier {
            return .evaluate(rest.first?.text == "(" ? expression(body) : .call(first.text, args, source: spelling(body), line: line), line: line)
        }
        let calls = nestedCalls(body)
        return .block(calls.map { .evaluate($0, line: line) })
    }

    private func nestedCalls(_ body: [Token]) -> [TextExpression] {
        var result: [TextExpression] = []
        var cursor = 0
        while cursor + 1 < body.count {
            if body[cursor].kind == .identifier, body[cursor + 1].text == "(" {
                var depth = 0
                var end = cursor + 1
                repeat {
                    if body[end].text == "(" { depth += 1 }
                    if body[end].text == ")" { depth -= 1 }
                    end += 1
                } while end < body.count && depth > 0
                result.append(expression(Array(body[cursor..<end])))
                cursor = end
            } else { cursor += 1 }
        }
        return result
    }

    /// rAthena also accepts conditions such as `(a) && (b)` without an outer pair.
    private mutating func conditionTokens() -> [Token] {
        let start = index
        _ = parenthesized()
        while index + 1 < tokens.count, ["&", "|"].contains(tokens[index].text), tokens[index + 1].text == tokens[index].text {
            index += 2
            _ = parenthesized()
        }
        return Array(tokens[start..<index])
    }

    private mutating func parenthesized() -> [Token] {
        guard punctuation("(") else { return [] }
        index += 1
        return read(until: ")")
    }

    private mutating func read(until delimiter: String) -> [Token] {
        let start = index
        var depth = 0
        while index < tokens.count {
            let token = tokens[index]
            if case .header = token.kind { break }
            if token.kind == .punctuation {
                if depth == 0 && token.text == delimiter {
                    let result = Array(tokens[start..<index]); index += 1; return result
                }
                if depth == 0 && ["{", "}"].contains(token.text) { break }
                if ["(", "["].contains(token.text) { depth += 1 }
                if [")", "]"].contains(token.text) { depth -= 1 }
            }
            index += 1
        }
        return Array(tokens[start..<index])
    }

    private func split(_ body: [Token], on delimiter: String) -> [[Token]] {
        var result: [[Token]] = [[]]
        var depth = 0
        for token in body {
            if token.kind == .punctuation {
                if depth == 0 && token.text == delimiter { result.append([]); continue }
                if ["(", "["].contains(token.text) { depth += 1 }
                if [")", "]"].contains(token.text) { depth -= 1 }
            }
            result[result.count - 1].append(token)
        }
        return result
    }

    private func expression(_ body: [Token]) -> TextExpression { ExpressionParser(source: source).parse(body) }
    private func spelling(_ body: [Token]) -> String {
        guard let first = body.first, let last = body.last else { return "" }
        return String(decoding: source[first.range.lowerBound..<last.range.upperBound], as: UTF8.self)
    }
    private func punctuation(_ value: String) -> Bool { index < tokens.count && tokens[index].kind == .punctuation && tokens[index].text == value }
    private func identifier(_ value: String) -> Bool { index < tokens.count && tokens[index].kind == .identifier && tokens[index].text.lowercased() == value }
}
