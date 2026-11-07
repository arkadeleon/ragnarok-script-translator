//
//  Expression.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/11/7.
//

import Foundation

/// Text-producing expression structure. Unknown operations retain their exact source spelling;
/// their internal strings are not necessarily player-visible text (SQL, map names, etc.).
indirect enum TextExpression {
    case literal(String)
    case unknown(String)
    case concatenate([TextExpression], source: String)
    case choice(TextExpression, TextExpression, source: String)
    case format([TextExpression], source: String)

    /// Bound expression expansion separately from page expansion. On overflow preserve the
    /// original expression rather than silently dropping one of its alternatives.
    func variants(limit: Int = 16) -> [[Segment]] {
        switch self {
        case .literal(let text): return [[.literal(text)]]
        case .unknown(let source): return [[.placeholder(source)]]
        case .choice(let yes, let no, let source):
            let values = unique(yes.variants(limit: limit) + no.variants(limit: limit))
            return values.count <= limit ? values : [[.placeholder(source)]]
        case .concatenate(let terms, let source):
            var result: [[Segment]] = [[]]
            for term in terms {
                let values = term.variants(limit: limit)
                guard result.count * values.count <= limit else { return [[.placeholder(source)]] }
                result = result.flatMap { prefix in values.map { prefix + $0 } }
            }
            return unique(result)
        case .format(let arguments, let source):
            guard let format = arguments.first else { return [[.placeholder(source)]] }
            var result: [[Segment]] = []
            for variant in format.variants(limit: limit) {
                // A dynamic format cannot be interpreted safely.
                var text = ""
                for segment in variant {
                    guard case .literal(let value) = segment else { return [[.placeholder(source)]] }
                    text += value
                }
                guard let values = formatted(text, arguments: Array(arguments.dropFirst()), limit: limit),
                      result.count + values.count <= limit else { return [[.placeholder(source)]] }
                result += values
            }
            return unique(result)
        }
    }

    private func unique(_ values: [[Segment]]) -> [[Segment]] {
        var result: [[Segment]] = []
        for value in values where !result.contains(value) { result.append(value) }
        return result
    }

    private func formatted(_ format: String, arguments: [TextExpression], limit: Int) -> [[Segment]]? {
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
        return TextExpression.concatenate(parts, source: format).variants(limit: limit)
    }

    private var sourceText: String {
        switch self {
        case .literal(let value): return String(reflecting: value)
        case .unknown(let source), .concatenate(_, let source), .format(_, let source), .choice(_, _, let source): return source
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
        if tokens.count == 1, tokens[0].kind == .string { return .literal(tokens[0].text) }
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
                        return .choice(parse(Array(tokens[(question + 1)..<index]), depth: depth + 1),
                                       parse(Array(tokens[(index + 1)...]), depth: depth + 1), source: raw)
                    }
                    nested -= 1
                }
            }
            return .unknown(raw)
        }
        if top.contains(where: { tokens[$0].kind == .punctuation && "=<>!|&^".contains(tokens[$0].text) }) {
            return .unknown(raw)
        }
        let pluses = top.filter { punctuation(tokens[$0], "+") }
        if !pluses.isEmpty {
            // Do not mistake ++ for concatenation.
            if pluses.contains(where: { $0 == 0 || $0 == tokens.count - 1 || punctuation(tokens[$0 - 1], "+") || punctuation(tokens[$0 + 1], "+") }) {
                return .unknown(raw)
            }
            var terms: [TextExpression] = []
            var start = 0
            for end in pluses + [tokens.count] {
                terms.append(parse(Array(tokens[start..<end]), depth: depth + 1))
                start = end + 1
            }
            // Pure numeric addition is one dynamic value, not several concatenated values.
            if !tokens.contains(where: { $0.kind == .string || ($0.kind == .identifier && $0.text.hasSuffix("$")) }) {
                return .unknown(raw)
            }
            return .concatenate(terms, source: raw)
        }
        if tokens.count >= 3, tokens[0].kind == .identifier,
           tokens[0].text.lowercased() == "sprintf", punctuation(tokens[1], "("),
           matchingClose(tokens, from: 1) == tokens.count - 1 {
            let inner = Array(tokens.dropFirst(2).dropLast())
            let commas = topLevel(inner).filter { punctuation(inner[$0], ",") }
            var arguments: [TextExpression] = []
            var start = 0
            for end in commas + [inner.count] {
                arguments.append(parse(Array(inner[start..<end]), depth: depth + 1))
                start = end + 1
            }
            return .format(arguments, source: raw)
        }
        return .unknown(raw)
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
