//
//  TextEnvironment.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/11/7.
//

import Foundation

/// A scalar is element zero of the corresponding rAthena array.
struct TextReference {
    var name: String
    var index: String?
    var source: String
}

/// Eager snapshots prevent aliases and self-referential appends from resolving against later
/// assignments. Each execution variant owns its environment; unrelated branches never share writes.
struct TextEnvironment: Equatable {
    private var strings: [String: [Int: [[Segment]]]] = [:]
    private var integers: [String: Int] = [:]
    private var unknownIndices: Set<String> = []

    func values(for reference: TextReference, limit: Int) -> [[Segment]] {
        let fallback: [[Segment]] = [[.placeholder(reference.source)]]
        guard reference.name.hasSuffix("$"), let elements = strings[reference.name] else { return fallback }
        if let index = offset(of: reference) {
            return elements[index] ?? fallback
        }
        if let index = reference.index, unknownIndices.contains(index) { return fallback }
        // An unknown subscript may select any known element, or an untracked/default value.
        // Keep that last possibility dynamic instead of guessing the server's array bounds.
        var values: [[Segment]] = []
        for index in elements.keys.sorted() {
            for value in elements[index]! where !values.contains(value) { values.append(value) }
        }
        values += fallback
        return values.count <= limit ? values : fallback
    }

    /// Bind a dynamic index variable to each candidate once, so parallel arrays read with
    /// the same index produce aligned lines instead of a Cartesian product of unrelated rows.
    func expansions(for expression: TextExpression) -> [(segments: [Segment], environment: TextEnvironment)] {
        var environments = [self]
        for reference in expression.references {
            guard let index = reference.index, !index.isEmpty,
                  index.allSatisfy({ $0.isLetter || $0.isNumber || "_.@$#'".contains($0) }),
                  Int(index) == nil else { continue }
            var expanded: [TextEnvironment] = []
            for environment in environments {
                guard environment.offset(of: reference) == nil, !environment.unknownIndices.contains(index),
                      let elements = environment.strings[reference.name], elements.count < 16 else {
                    expanded.append(environment)
                    continue
                }
                for offset in elements.keys.sorted() {
                    var candidate = environment
                    candidate.integers[index] = offset
                    expanded.append(candidate)
                }
                var unknown = environment
                unknown.unknownIndices.insert(index)
                expanded.append(unknown)
            }
            // Fall back to bounded expression evaluation if several independent indices explode.
            if expanded.count > 16 { break }
            environments = expanded
        }
        return environments.flatMap { environment in
            expression.variants(in: environment).map { ($0, environment) }
        }
    }

    mutating func assign(_ reference: TextReference, values expressions: [TextExpression], append: Bool) {
        guard let start = offset(of: reference), start >= 0 else {
            forget([reference.name])
            return
        }
        if !reference.name.hasSuffix("$") {
            // Numeric constants are useful for fixed array subscripts; arithmetic stays dynamic.
            unknownIndices.remove(reference.name)
            if start == 0, !append, let expression = expressions.first {
                integers[reference.name] = integer(expression.sourceText)
            } else {
                integers.removeValue(forKey: reference.name)
            }
            return
        }
        let snapshot = self
        for (offset, expression) in expressions.enumerated() {
            guard offset <= Int.max - start else { break }
            let target = start + offset
            let values: [[Segment]]
            if append {
                let previous = snapshot.values(for: reference, limit: 16)
                let suffixes = expression.variants(in: snapshot)
                if previous.count * suffixes.count <= 16 {
                    values = previous.flatMap { prefix in suffixes.map { prefix + $0 } }
                } else {
                    values = [[.placeholder(reference.source)]]
                }
            } else {
                values = expression.variants(in: snapshot)
            }
            strings[reference.name, default: [:]][target] = values
        }
    }

    mutating func forget(_ names: [String]) {
        for name in names {
            strings.removeValue(forKey: name)
            integers.removeValue(forKey: name)
            unknownIndices.remove(name)
        }
    }

    /// When page enumeration reaches its cap, retain a bounded union of reaching values.
    /// Correlation is lost at that boundary, but later pages can still resolve known text.
    static func joined(_ environments: [TextEnvironment]) -> TextEnvironment {
        var result = TextEnvironment()
        // Keep "unknown" bindings only when all reaching paths agree; otherwise the union
        // below must retain candidate text for subsequent reads.
        if let first = environments.first {
            result.unknownIndices = first.unknownIndices.filter { index in
                environments.allSatisfy { $0.unknownIndices.contains(index) }
            }
        }
        let names = Set(environments.flatMap { $0.strings.keys })
        for name in names {
            let indices = Set(environments.flatMap { $0.strings[name]?.keys.map { $0 } ?? [] })
            for index in indices {
                let fallback: [[Segment]] = [[.placeholder(index == 0 ? name : "\(name)[\(index)]")]]
                var values: [[Segment]] = []
                for environment in environments {
                    for value in environment.strings[name]?[index] ?? fallback where !values.contains(value) {
                        values.append(value)
                    }
                }
                result.strings[name, default: [:]][index] = values.count <= 16 ? values : fallback
            }
        }
        if let first = environments.first {
            for (name, value) in first.integers where environments.allSatisfy({ $0.integers[name] == value }) {
                result.integers[name] = value
            }
        }
        return result
    }

    func offset(of reference: TextReference) -> Int? {
        guard let index = reference.index else { return 0 }
        return integer(index)
    }

    private func integer(_ source: String) -> Int? {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Int(value) { return number }
        if value.hasPrefix("0x") { return Int(value.dropFirst(2), radix: 16) }
        return integers[value]
    }
}
