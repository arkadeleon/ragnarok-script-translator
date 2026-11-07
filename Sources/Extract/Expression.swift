//
//  Expression.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/11/7.
//

import Foundation

/// Text-producing expression structure. Unknown operations retain their exact source spelling;
/// their internal strings are not necessarily player-visible text (SQL, map names, etc.).
indirect enum TextExpression: Equatable {
    case literal(String)
    case number(Int, source: String)
    case operation(String, [TextExpression], source: String)
    case call(String, [TextExpression], source: String, line: Int = 1)
    case unknown(String)
    case reference(TextReference)
    case concatenate([TextExpression], source: String)
    case choice(TextExpression, TextExpression, TextExpression, source: String)
    case format([TextExpression], source: String)

    /// Bound expression expansion separately from page expansion. On overflow preserve the
    /// original expression rather than silently dropping one of its alternatives.
    func variants(in environment: TextEnvironment = TextEnvironment(), limit: Int = 16) -> [[Segment]] {
        switch self {
        case .literal(let text): return [[.literal(text)]]
        case .number(let value, _): return [[.literal(String(value))]]
        case .operation(_, _, let source):
            return integer(in: environment).map { [[.literal(String($0))]] } ?? [[.placeholder(source)]]
        case .call(let name, let arguments, let source, _):
            if name.lowercased() == "getarg", let index = arguments.first?.integer(in: environment), index >= 0 {
                if index < environment.arguments.count { return environment.arguments[index].variants(in: environment, limit: limit) }
                if arguments.count > 1 { return arguments[1].variants(in: environment, limit: limit) }
            }
            if name.lowercased() == "getargcount", environment.argumentsKnown { return [[.literal(String(environment.arguments.count))]] }
            if name.lowercased() == "getarraysize", let value = integer(in: environment) { return [[.literal(String(value))]] }
            return [[.placeholder(source)]]
        case .unknown(let source): return [[.placeholder(source)]]
        case .reference(let reference): return environment.values(for: reference, limit: limit)
        case .choice(let condition, let yes, let no, let source):
            if let value = condition.integer(in: environment) { return (value != 0 ? yes : no).variants(in: environment, limit: limit) }
            let values = unique(yes.variants(in: environment, limit: limit) + no.variants(in: environment, limit: limit))
            return values.count <= limit ? values : [[.placeholder(source)]]
        case .concatenate(let terms, let source):
            var result: [[Segment]] = [[]]
            for term in terms {
                let values = term.variants(in: environment, limit: limit)
                guard result.count * values.count <= limit else { return [[.placeholder(source)]] }
                result = result.flatMap { prefix in values.map { prefix + $0 } }
            }
            return unique(result)
        case .format(let arguments, let source):
            guard let format = arguments.first else { return [[.placeholder(source)]] }
            var result: [[Segment]] = []
            for variant in format.variants(in: environment, limit: limit) {
                // A dynamic format cannot be interpreted safely.
                var text = ""
                for segment in variant {
                    guard case .literal(let value) = segment else { return [[.placeholder(source)]] }
                    text += value
                }
                guard let values = formatted(text, arguments: Array(arguments.dropFirst()), environment: environment, limit: limit),
                      result.count + values.count <= limit else { return [[.placeholder(source)]] }
                result += values
            }
            return unique(result)
        }
    }

    func integer(in environment: TextEnvironment) -> Int? {
        switch self {
        case .number(let value, _): return value
        case .literal: return nil
        case .reference(let reference): return environment.integerValue(reference)
        case .choice(let condition, let yes, let no, _):
            guard let value = condition.integer(in: environment) else { return nil }
            return (value != 0 ? yes : no).integer(in: environment)
        case .call(let name, let arguments, _, _):
            if name.lowercased() == "getargcount" { return environment.argumentsKnown ? environment.arguments.count : nil }
            if name.lowercased() == "getarraysize", let first = arguments.first, case .reference(let reference) = first {
                return environment.arraySize(reference)
            }
            if name.lowercased() == "getarg", let index = arguments.first?.integer(in: environment), index >= 0 {
                if index < environment.arguments.count { return environment.arguments[index].integer(in: environment) }
                if arguments.count > 1 { return arguments[1].integer(in: environment) }
            }
            return nil
        case .operation(let op, let terms, _):
            guard let first = terms.first else { return nil }
            let lhs = first.integer(in: environment)
            if op == "&&", lhs == 0 { return 0 }
            if op == "||", let lhs, lhs != 0 { return 1 }
            guard let lhs else { return nil }
            if terms.count == 1 {
                switch op {
                case "!": return lhs == 0 ? 1 : 0
                case "~": return ~lhs
                case "-": return lhs == Int.min ? nil : -lhs
                case "+": return lhs
                default: return nil
                }
            }
            guard let rhs = terms[1].integer(in: environment) else { return nil }
            switch op {
            case "+": let (value, overflow) = lhs.addingReportingOverflow(rhs); return overflow ? nil : value
            case "-": let (value, overflow) = lhs.subtractingReportingOverflow(rhs); return overflow ? nil : value
            case "*": let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs); return overflow ? nil : value
            case "/": return rhs == 0 || (lhs == Int.min && rhs == -1) ? nil : lhs / rhs
            case "%": return rhs == 0 || (lhs == Int.min && rhs == -1) ? nil : lhs % rhs
            case "==": return lhs == rhs ? 1 : 0
            case "!=": return lhs != rhs ? 1 : 0
            case "<": return lhs < rhs ? 1 : 0
            case ">": return lhs > rhs ? 1 : 0
            case "<=": return lhs <= rhs ? 1 : 0
            case ">=": return lhs >= rhs ? 1 : 0
            case "&&": return lhs != 0 && rhs != 0 ? 1 : 0
            case "||": return lhs != 0 || rhs != 0 ? 1 : 0
            case "&": return lhs & rhs
            case "|": return lhs | rhs
            case "^": return lhs ^ rhs
            case "<<": return (0..<64).contains(rhs) ? lhs << rhs : nil
            case ">>": return (0..<64).contains(rhs) ? lhs >> rhs : nil
            default: return nil
            }
        case .concatenate, .format, .unknown: return nil
        }
    }

    var mayBeText: Bool {
        switch self {
        case .literal, .concatenate, .format, .call: return true
        case .choice(_, let yes, let no, _): return yes.mayBeText || no.mayBeText
        case .reference(let reference): return reference.name.hasSuffix("$")
        case .number, .operation, .unknown: return false
        }
    }

    func isText(in environment: TextEnvironment) -> Bool {
        switch self {
        case .literal, .format: return true
        case .concatenate(let terms, _): return terms.contains { $0.isText(in: environment) }
        case .reference(let reference): return reference.name.hasSuffix("$")
        case .call(let name, let parameters, _, _):
            if name.lowercased() == "getarg", let index = parameters.first?.integer(in: environment), index >= 0 {
                if index < environment.arguments.count { return environment.arguments[index].isText(in: environment) }
                if parameters.count > 1 { return parameters[1].isText(in: environment) }
            }
            return ["strcharinfo", "strnpcinfo", "getitemname", "getpartyname", "getguildname"].contains(name.lowercased())
        case .choice(_, let yes, let no, _): return yes.isText(in: environment) && no.isText(in: environment)
        default: return false
        }
    }

    var sourceLine: Int {
        switch self {
        case .reference(let reference): return reference.line
        case .call(_, _, _, let line): return line
        case .concatenate(let terms, _), .format(let terms, _), .operation(_, let terms, _): return terms.first?.sourceLine ?? 1
        case .choice(let condition, _, _, _): return condition.sourceLine
        default: return 1
        }
    }

    var references: [TextReference] {
        switch self {
        case .reference(let reference): return [reference]
        case .concatenate(let terms, _), .format(let terms, _), .operation(_, let terms, _), .call(_, let terms, _, _): return terms.flatMap(\.references)
        case .choice(let condition, let yes, let no, _): return condition.references + yes.references + no.references
        case .literal, .number, .unknown: return []
        }
    }

    private func unique(_ values: [[Segment]]) -> [[Segment]] {
        var result: [[Segment]] = []
        for value in values where !result.contains(value) { result.append(value) }
        return result
    }

    private func formatted(_ format: String, arguments: [TextExpression], environment: TextEnvironment, limit: Int) -> [[Segment]]? {
        // rAthena returns the format verbatim when there are no value arguments.
        if arguments.isEmpty { return [[.literal(format)]] }
        let chars = Array(format)
        var index = 0
        var argument = 0
        var literal = ""
        var parts: [TextExpression] = []
        while index < chars.count {
            guard chars[index] == "%" else { literal.append(chars[index]); index += 1; continue }
            index += 1
            guard index < chars.count else { return nil }
            if chars[index] == "%" { literal.append("%"); index += 1; continue }
            parts.append(.literal(literal))
            literal = ""
            // Start with plain conversions only. Flags, widths, precisions and positional
            // arguments need their own semantics; never emit them as visible text.
            guard "sdixXuocfeEgG".contains(chars[index]), argument < arguments.count else { return nil }
            if chars[index] == "s" {
                parts.append(arguments[argument])
            } else {
                // Numeric formatting changes the rendered value. Keep the whole conversion
                // as one placeholder, even when its argument is a numeric literal.
                parts.append(.unknown("sprintf(\"%\(chars[index])\", \(arguments[argument].sourceText))"))
            }
            argument += 1
            index += 1
        }
        parts.append(.literal(literal))
        return TextExpression.concatenate(parts, source: format).variants(in: environment, limit: limit)
    }

    var sourceText: String {
        switch self {
        case .literal(let value): return String(reflecting: value)
        case .reference(let reference): return reference.source
        case .unknown(let source), .concatenate(_, let source), .format(_, let source), .choice(_, _, _, let source), .number(_, let source), .operation(_, _, let source), .call(_, _, let source, _): return source
        }
    }
}

/// Recognizes text operations without treating strings inside arbitrary calls as translations.
/// Lower-precedence operators are checked before concatenation so arithmetic/comparisons remain
/// opaque. A full numeric evaluator is intentionally outside the text extraction layer.
struct ExpressionParser {
    let source: [UInt8]

    func parse(_ tokens: [Token], depth: Int = 0) -> TextExpression {
        let raw = spelling(tokens)
        guard !tokens.isEmpty, depth < 128 else { return .unknown(raw) }
        if tokens.count == 1 {
            if tokens[0].kind == .string { return .literal(tokens[0].text) }
            if tokens[0].kind == .number {
                let value = raw.lowercased().hasPrefix("0x") ? Int(raw.dropFirst(2), radix: 16) : Int(raw)
                if let value { return .number(value, source: raw) }
            }
            if raw == "true" || raw == "false" { return .number(raw == "true" ? 1 : 0, source: raw) }
        }
        if tokens[0].kind == .identifier {
            if tokens.count == 1 { return .reference(TextReference(name: raw, index: nil, source: raw, line: tokens[0].line)) }
            if tokens.count >= 4, punctuation(tokens[1], "["), punctuation(tokens.last, "]") {
                let inner = Array(tokens.dropFirst(2).dropLast())
                if !inner.isEmpty, topLevel(tokens).count == 1 {
                    return .reference(TextReference(name: tokens[0].text, index: spelling(inner), source: raw, line: tokens[0].line))
                }
            }
        }
        let top = topLevel(tokens)
        if punctuation(tokens.first, "("), matchingClose(tokens, from: 0) == tokens.count - 1 {
            return parse(Array(tokens.dropFirst().dropLast()), depth: depth + 1)
        }
        if let question = top.first(where: { punctuation(tokens[$0], "?") }) {
            var nested = 0
            for index in top where index > question {
                if punctuation(tokens[index], "?") { nested += 1 }
                if punctuation(tokens[index], ":") {
                    if nested == 0 {
                        return .choice(parse(Array(tokens[..<question]), depth: depth + 1), parse(Array(tokens[(question + 1)..<index]), depth: depth + 1),
                                       parse(Array(tokens[(index + 1)...]), depth: depth + 1), source: raw)
                    }
                    nested -= 1
                }
            }
            return .unknown(raw)
        }
        if let binary = binary(tokens, top: top, depth: depth) { return binary }
        if let first = tokens.first, first.kind == .punctuation, ["!", "~", "-", "+"].contains(first.text) {
            return .operation(first.text, [parse(Array(tokens.dropFirst()), depth: depth + 1)], source: raw)
        }
        if tokens.count >= 3, tokens[0].kind == .identifier,
           punctuation(tokens[1], "("),
           matchingClose(tokens, from: 1) == tokens.count - 1 {
            let inner = Array(tokens.dropFirst(2).dropLast())
            if inner.isEmpty {
                return tokens[0].text.lowercased() == "sprintf" ? .format([], source: raw) : .call(tokens[0].text, [], source: raw, line: tokens[0].line)
            }
            let commas = topLevel(inner).filter { punctuation(inner[$0], ",") }
            var arguments: [TextExpression] = []
            var start = 0
            for end in commas + [inner.count] {
                arguments.append(parse(Array(inner[start..<end]), depth: depth + 1))
                start = end + 1
            }
            return tokens[0].text.lowercased() == "sprintf" ? .format(arguments, source: raw) : .call(tokens[0].text, arguments, source: raw, line: tokens[0].line)
        }
        return .unknown(raw)
    }

    /// Fold equal-precedence operators iteratively. A long sequence must not consume one
    /// parser stack frame per term on Swift's smaller async worker stacks.
    private func binary(_ tokens: [Token], top: [Int], depth: Int) -> TextExpression? {
        let precedence = [["||"], ["&&"], ["|"], ["^"], ["&"], ["==", "!="], ["<=", ">=", "<", ">"], ["<<", ">>"], ["+", "-"], ["*", "/", "%"]]
        var operators: [(Int, String, Int)] = []
        var skipped: Set<Int> = []
        for position in top where tokens[position].kind == .punctuation && !skipped.contains(position) {
            var op = tokens[position].text
            var width = 1
            if position + 1 < tokens.count, top.contains(position + 1) {
                let pair = op + tokens[position + 1].text
                if ["||", "&&", "==", "!=", "<=", ">=", "<<", ">>"].contains(pair) { op = pair; width = 2; skipped.insert(position + 1) }
            }
            if position == 0 { continue }
            let previous = tokens[position - 1]
            if previous.kind == .punctuation, ![")", "]"].contains(previous.text) { continue }
            operators.append((position, op, width))
        }
        for group in precedence {
            let matching = operators.filter { group.contains($0.1) && $0.0 + $0.2 < tokens.count }
            guard let first = matching.first else { continue }
            var result = parse(Array(tokens[..<first.0]), depth: depth + 1)
            for (offset, item) in matching.enumerated() {
                let (position, op, width) = item
                let end = offset + 1 < matching.count ? matching[offset + 1].0 : tokens.count
                let rhs = parse(Array(tokens[(position + width)..<end]), depth: depth + 1)
                if op == "+", result.mayBeText || rhs.mayBeText {
                    if case .literal(let left) = result, case .literal(let right) = rhs { result = .literal(left + right) }
                    else if case .concatenate(let terms, _) = result, result.isText(in: TextEnvironment()) {
                        result = .concatenate(terms + [rhs], source: spelling(Array(tokens[..<end])))
                    } else { result = .concatenate([result, rhs], source: spelling(Array(tokens[..<end]))) }
                } else {
                    result = .operation(op, [result, rhs], source: spelling(Array(tokens[..<end])))
                    if let value = result.integer(in: TextEnvironment()) { result = .number(value, source: result.sourceText) }
                }
            }
            return result
        }
        return nil
    }

    private func spelling(_ tokens: [Token]) -> String {
        guard let first = tokens.first, let last = tokens.last else { return "" }
        return String(decoding: source[first.range.lowerBound..<last.range.upperBound], as: UTF8.self)
    }

    private func punctuation(_ token: Token?, _ text: String) -> Bool {
        token?.kind == .punctuation && token?.text == text
    }

    private func topLevel(_ tokens: [Token]) -> [Int] {
        var depth = 0
        var result: [Int] = []
        for index in tokens.indices {
            let token = tokens[index]
            if punctuation(token, "(") || punctuation(token, "[") { depth += 1 }
            if depth == 0 { result.append(index) }
            if punctuation(token, ")") || punctuation(token, "]") { depth -= 1 }
        }
        return result
    }

    private func matchingClose(_ tokens: [Token], from start: Int) -> Int? {
        var depth = 0
        for index in start..<tokens.count {
            if punctuation(tokens[index], "(") { depth += 1 }
            if punctuation(tokens[index], ")") {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }
}
