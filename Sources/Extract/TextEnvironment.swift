//
//  TextEnvironment.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/11/7.
//

import Foundation

/// A scalar is element zero of the corresponding rAthena array.
struct TextReference: Equatable {
    var name: String
    var index: String?
    var source: String
    var line = 1
}

enum ArgumentTarget: Equatable {
    case variable(TextReference)
    case argument(Int)
}

/// Eager snapshots prevent aliases and self-referential appends from resolving against later
/// assignments. Each execution variant owns its environment; unrelated branches never share writes.
struct TextEnvironment: Equatable {
    var arguments: [TextExpression] = []
    var argumentsKnown = false
    private var argumentTargets: [ArgumentTarget?] = []
    private var argumentWrites: [Int: TextExpression] = [:]
    private var argumentInvalidations: Set<Int> = []
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
                integers[reference.name] = expression.integer(in: self)
            } else if start == 0, append, let old = integers[reference.name], let value = expressions.first?.integer(in: self) {
                let (sum, overflow) = old.addingReportingOverflow(value)
                integers[reference.name] = overflow ? nil : sum
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
            result.arguments = first.arguments
            result.argumentsKnown = environments.allSatisfy { $0.argumentsKnown }
            result.argumentTargets = first.argumentTargets
            for index in first.arguments.indices {
                if environments.contains(where: { $0.argumentInvalidations.contains(index) || $0.argumentWrites[index] != first.argumentWrites[index] }) {
                    result.argumentInvalidations.insert(index)
                } else if let value = first.argumentWrites[index] { result.argumentWrites[index] = value }
            }
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

    func arraySize(_ reference: TextReference) -> Int? {
        guard let elements = strings[reference.name] else { return nil }
        var last = -1
        for (index, variants) in elements {
            var occupied: Set<Bool> = []
            for segments in variants {
                var text = ""
                for segment in segments {
                    guard case .literal(let value) = segment else { return nil }
                    text += value
                }
                occupied.insert(!text.isEmpty)
            }
            guard occupied.count == 1 else { return nil }
            if occupied.contains(true) { last = max(last, index) }
        }
        return last == Int.max ? nil : last + 1
    }

    func integerValue(_ reference: TextReference) -> Int? {
        guard offset(of: reference) == 0 else { return nil }
        return integers[reference.name]
    }

    func enteringCall(arguments: [TextExpression], targets: [ArgumentTarget?] = [], separateNPC: Bool = false) -> TextEnvironment {
        var result = self
        result.strings = strings.filter { !$0.key.hasPrefix(separateNPC ? "." : ".@") }
        result.integers = integers.filter { !$0.key.hasPrefix(separateNPC ? "." : ".@") }
        result.unknownIndices = unknownIndices.filter { !$0.hasPrefix(separateNPC ? "." : ".@") }
        result.arguments = arguments
        result.argumentsKnown = true
        result.argumentTargets = targets
        result.argumentWrites = [:]
        result.argumentInvalidations = []
        return result
    }

    func returning(to caller: TextEnvironment, separateNPC: Bool = false) -> TextEnvironment {
        var result = enteringCall(arguments: caller.arguments, separateNPC: separateNPC)
        result.argumentsKnown = caller.argumentsKnown
        result.argumentTargets = caller.argumentTargets
        result.argumentWrites = caller.argumentWrites
        result.argumentInvalidations = caller.argumentInvalidations
        for (name, value) in caller.strings where name.hasPrefix(separateNPC ? "." : ".@") { result.strings[name] = value }
        for (name, value) in caller.integers where name.hasPrefix(separateNPC ? "." : ".@") { result.integers[name] = value }
        result.unknownIndices.formUnion(caller.unknownIndices.filter { $0.hasPrefix(separateNPC ? "." : ".@") })
        for index in argumentInvalidations.sorted() where argumentTargets.indices.contains(index) {
            switch argumentTargets[index] {
            case .variable(let target): result.forget([target.name])
            case .argument(let position): result.invalidateArgument(position)
            case nil: break
            }
        }
        for index in argumentWrites.keys.sorted() where argumentTargets.indices.contains(index) && !argumentInvalidations.contains(index) {
            guard let value = argumentWrites[index] else { continue }
            switch argumentTargets[index] {
            case .variable(let target): result.assign(target, values: [value], append: false)
            case .argument(let position): result.writeArgument(position, value: value)
            case nil: break
            }
        }
        return result
    }

    func argumentTarget(for expression: TextExpression) -> ArgumentTarget? {
        if case .reference(var target) = expression {
            if target.index != nil, let index = offset(of: target) { target.index = String(index) }
            target.line = 1
            target.source = target.name + (target.index.map { "[" + $0 + "]" } ?? "")
            return .variable(target)
        }
        if case .call(let name, let parameters, _, _) = expression, name.lowercased() == "getarg",
           let index = parameters.first?.integer(in: self) { return .argument(index) }
        return nil
    }

    mutating func writeArgument(_ index: Int, value: TextExpression) {
        guard arguments.indices.contains(index) else { return }
        arguments[index] = value
        argumentWrites[index] = value
        argumentInvalidations.remove(index)
        if argumentTargets.indices.contains(index), let target = argumentTargets[index] {
            for alias in argumentTargets.indices where alias != index && argumentTargets[alias] == target {
                arguments[alias] = value
                argumentWrites[alias] = value
                argumentInvalidations.remove(alias)
            }
        }
    }

    mutating func invalidateAllArguments() {
        for index in arguments.indices { invalidateArgument(index) }
    }

    mutating func invalidateArgument(_ index: Int) {
        guard arguments.indices.contains(index) else { return }
        argumentInvalidations.insert(index)
        arguments[index] = .unknown("getarg(\(index))")
        argumentWrites.removeValue(forKey: index)
    }

    func initializationValues() -> TextEnvironment {
        var result = TextEnvironment()
        result.strings = strings.filter { $0.key.hasPrefix(".") && !$0.key.hasPrefix(".@") }
        result.integers = integers.filter { $0.key.hasPrefix(".") && !$0.key.hasPrefix(".@") }
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
        if let known = integers[value] { return known }
        if value.contains(where: { "+-*/%[]".contains($0) }) {
            var tokenizer = ScriptTokenizer(expression: value)
            return ExpressionParser(source: Array(value.utf8)).parse(tokenizer.tokenize()).integer(in: self)
        }
        return nil
    }
}
