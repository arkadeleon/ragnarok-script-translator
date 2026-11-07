//
//  ScriptFlow.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/11/7.
//

struct ScriptGraph {
    enum Node {
        case action(Statement, next: Int)
        case branch(TextExpression, yes: Int, no: Int)
        case dispatch(TextExpression, [(TextExpression?, Int)], otherwise: Int)
        case jump(Int)
        case labelJump(String)
        case menu([(TextExpression, String)], line: Int, next: Int)
        case returnValue(TextExpression?)
        case stop
        case finish
    }

    var nodes: [Node] = [.finish]
    var entry = 0
    var labels: [String: Int] = [:]
    var functions: [String: ScriptGraph] = [:]
    var loopExits: [Int: Int] = [:]

    init(_ statement: Statement) {
        entry = compile(statement, next: 0, breaking: 0, continuing: 0)
    }

    private mutating func add(_ node: Node) -> Int { nodes.append(node); return nodes.count - 1 }

    private mutating func compile(_ statement: Statement, next: Int, breaking: Int, continuing: Int) -> Int {
        switch statement {
        case .block(let body):
            return body.reversed().reduce(next) { compile($1, next: $0, breaking: breaking, continuing: continuing) }
        case .branch(let arms, let otherwise):
            var fallback = otherwise.map { compile($0, next: next, breaking: breaking, continuing: continuing) } ?? next
            for arm in arms.reversed() {
                let yes = compile(arm.body, next: next, breaking: breaking, continuing: continuing)
                fallback = add(.branch(arm.condition, yes: yes, no: fallback))
            }
            return fallback
        case .switchValue(let value, let arms):
            var targets: [(TextExpression?, Int)] = []
            var fallen = next
            for arm in arms.reversed() {
                fallen = compile(arm.body, next: fallen, breaking: next, continuing: continuing)
                targets.insert((arm.value, fallen), at: 0)
            }
            return add(.dispatch(value, targets, otherwise: next))
        case .loop(let initial, let condition, let step, let body, let atLeastOnce):
            let header = add(.finish)
            let update = compile(step, next: header, breaking: next, continuing: header)
            let bodyEntry = compile(body, next: update, breaking: next, continuing: update)
            nodes[header] = condition.map { .branch($0, yes: bodyEntry, no: next) } ?? .jump(bodyEntry)
            loopExits[header] = next
            return compile(initial, next: atLeastOnce ? bodyEntry : header, breaking: next, continuing: update)
        case .label(let name): labels[name] = next; return next
        case .function(let name, let body): functions[name] = ScriptGraph(body); return next
        case .menu(let entries, let line): return add(.menu(entries, line: line, next: next))
        case .jump(let name): return add(.labelJump(name))
        case .breakLoop: return add(.jump(breaking))
        case .continueLoop: return add(.jump(continuing))
        case .returnValue(let value): return add(.returnValue(value))
        case .terminate: return add(.stop)
        case .transparent: return next
        default: return add(.action(statement, next: next))
        }
    }
}

/// Shared by all files during command extraction; standalone extractors use a file-local library.
struct ScriptLibrary {
    var functions: [String: [ScriptGraph]] = [:]

    init(scripts: [ParsedScript]) {
        for script in scripts where script.isFunction {
            functions[script.name, default: []].append(ScriptGraph(.block(script.statements)))
        }
    }
}

private struct FlowState: Equatable {
    var environment = TextEnvironment()
    var page: [[Segment]] = []
    var line = 0
    var stopped = false
}

private struct FlowResult {
    var state: FlowState
    var value: TextExpression
}

/// Bounded abstract execution of the graph. Unknown conditions fork; constant conditions select
/// one edge. On state/iteration limits pending pages are emitted as fragments before continuing.
final class ScriptFlowInterpreter {
    private let library: ScriptLibrary
    private let npc: String?
    private let emit: (ExtractedScript) -> Void
    private var remainingInstructions = 0

    init(library: ScriptLibrary, npc: String?, emit: @escaping (ExtractedScript) -> Void) {
        self.library = library
        self.npc = npc
        self.emit = emit
    }

    func run(_ graph: ScriptGraph) {
        remainingInstructions = max(4096, min(graph.nodes.count * 8, 40000))
        var initial = TextEnvironment()
        if let entry = graph.labels["OnInit"] {
            let results = execute(graph, entry: entry, state: FlowState(), depth: 0, callLine: nil)
            initial = .joined(results.map { $0.state.environment.initializationValues() })
            for result in results { flush(result.state) }
        }
        let events = graph.labels.keys.filter { $0.hasPrefix("On") && $0 != "OnInit" }.sorted()
        let entries = [graph.entry] + events.compactMap { graph.labels[$0] }
        for entry in entries {
            remainingInstructions = max(4096, min(graph.nodes.count * 8, 40000))
            let results = execute(graph, entry: entry, state: FlowState(environment: initial), depth: 0, callLine: nil)
            for result in results { flush(result.state) }
        }
    }

    private func execute(_ graph: ScriptGraph, entry: Int, state: FlowState, depth: Int, callLine: Int?) -> [FlowResult] {
        struct Work {
            var pc: Int
            var state: FlowState
            var visits: [Int: Int] = [:]
        }
        var pending = [Work(pc: entry, state: state)]
        var cursor = 0
        var seen: [Int: [FlowState]] = [:]
        var merged: Set<Int> = []
        var results: [FlowResult] = []
        while cursor < pending.count, remainingInstructions > 0 {
            var work = pending[cursor]; cursor += 1
            remainingInstructions -= 1
            guard graph.nodes.indices.contains(work.pc) else { flush(work.state); continue }
            if seen[work.pc, default: []].contains(work.state) { continue }
            if seen[work.pc, default: []].count >= 16 {
                flush(work.state)
                guard merged.insert(work.pc).inserted else { continue }
                let states = seen[work.pc, default: []] + [work.state]
                work.state.environment = .joined(states.map(\.environment))
                work.state.page = []
                work.state.line = 0
            } else { seen[work.pc, default: []].append(work.state) }
            let visits = work.visits[work.pc, default: 0]
            if visits >= 64 {
                flush(work.state)
                if let exit = graph.loopExits[work.pc] { work.pc = exit; pending.append(work) }
                continue
            }
            work.visits[work.pc] = visits + 1
            func enqueue(_ pc: Int, _ state: FlowState) {
                if state.stopped { results.append(.init(state: state, value: .unknown(""))); return }
                pending.append(Work(pc: pc, state: state, visits: work.visits))
            }
            switch graph.nodes[work.pc] {
            case .finish: results.append(.init(state: work.state, value: .unknown("")))
            case .stop:
                var stopped = work.state; stopped.stopped = true
                results.append(.init(state: stopped, value: .unknown("")))
            case .returnValue(let expression):
                if let expression {
                    results += evaluate(expression, state: work.state, graph: graph, depth: depth, line: callLine ?? expression.sourceLine)
                } else { results.append(.init(state: work.state, value: .unknown(""))) }
            case .jump(let target): enqueue(target, work.state)
            case .labelJump(let label):
                if let target = graph.labels[label] { enqueue(target, work.state) } else { flush(work.state) }
            case .menu(let entries, let line, let next):
                for (text, label) in entries {
                    for evaluated in evaluate(text, state: work.state, graph: graph, depth: depth, line: callLine ?? line) {
                        options(evaluated.value, state: evaluated.state, line: callLine ?? line)
                        if literal(evaluated.value, environment: evaluated.state.environment) == "" { continue }
                        if label == "-" { enqueue(next, evaluated.state) }
                        else if let target = graph.labels[label] { enqueue(target, evaluated.state) }
                    }
                }
            case .branch(let expression, let yes, let no):
                for evaluated in evaluate(expression, state: work.state, graph: graph, depth: depth, line: callLine ?? expression.sourceLine) {
                    if let value = evaluated.value.integer(in: evaluated.state.environment) {
                        enqueue(value == 0 ? no : yes, evaluated.state)
                    } else {
                        enqueue(no, evaluated.state)
                        if visits < 8 || graph.loopExits[work.pc] == nil { enqueue(yes, evaluated.state) }
                    }
                }
            case .dispatch(let expression, let cases, let otherwise):
                for evaluated in evaluate(expression, state: work.state, graph: graph, depth: depth, line: callLine ?? expression.sourceLine) {
                    let defaultTarget = cases.first(where: { $0.0 == nil })?.1 ?? otherwise
                    if let value = evaluated.value.integer(in: evaluated.state.environment),
                       cases.allSatisfy({ $0.0 == nil || $0.0?.integer(in: evaluated.state.environment) != nil }) {
                        let target = cases.first { $0.0?.integer(in: evaluated.state.environment) == value }?.1 ?? defaultTarget
                        enqueue(target, evaluated.state)
                    } else {
                        for target in Array(Set(cases.map(\.1) + [defaultTarget])).sorted() { enqueue(target, evaluated.state) }
                    }
                }
            case .action(let statement, let next):
                for state in action(statement, state: work.state, graph: graph, depth: depth, callLine: callLine) { enqueue(next, state) }
            }
        }
        // Reaching the budget must not erase text already collected on pending paths.
        for work in pending.dropFirst(cursor) { flush(work.state) }
        return boundResults(results)
    }

    private func action(_ statement: Statement, state: FlowState, graph: ScriptGraph, depth: Int, callLine: Int?) -> [FlowState] {
        if state.stopped { return [state] }
        switch statement {
        case .mes(let lines):
            var states = [state]
            for line in lines {
                var after: [FlowState] = []
                for before in states {
                    for evaluated in evaluate(line.expression, state: before, graph: graph, depth: depth, line: callLine ?? line.line) {
                        if evaluated.state.stopped { after.append(evaluated.state); continue }
                        for (segments, environment) in evaluated.state.environment.expansions(for: evaluated.value) {
                            var value = evaluated.state
                            value.environment = environment
                            if value.page.isEmpty { value.line = callLine ?? line.line }
                            value.page.append(segments)
                            after.append(value)
                        }
                    }
                }
                states = bounded(after)
            }
            return states
        case .assign(let target, let expressions, let append):
            var candidates: [(FlowState, [TextExpression])] = [(state, [])]
            for expression in expressions {
                var after: [(FlowState, [TextExpression])] = []
                for (before, arguments) in candidates {
                    for evaluated in evaluate(expression, state: before, graph: graph, depth: depth, line: callLine ?? target.line) {
                        after.append((evaluated.state, arguments + [evaluated.value]))
                    }
                }
                candidates = boundCandidates(after)
            }
            var after: [FlowState] = []
            for (before, values) in candidates {
                if values.count == 1, let expression = values.first {
                    for (segments, environment) in before.environment.expansions(for: expression) {
                        var result = before
                        result.environment = environment
                        let value = snapshot(expression, segments: segments, environment: environment)
                        result.environment.assign(target, values: [value], append: append)
                        after.append(result)
                    }
                } else {
                    var result = before
                    result.environment.assign(target, values: values, append: append)
                    after.append(result)
                }
            }
            return bounded(after)
        case .assignArgument(let index, let expression):
            guard let position = index.integer(in: state.environment) else {
                var result = state; result.environment.invalidateAllArguments(); return [result]
            }
            return evaluate(expression, state: state, graph: graph, depth: depth, line: callLine ?? expression.sourceLine).map { evaluated in
                var result = evaluated.state
                result.environment.writeArgument(position, value: snapshot(evaluated.value, environment: result.environment))
                return result
            }
        case .invalidateArgument(let expression):
            var result = state
            if let position = expression.integer(in: state.environment) { result.environment.invalidateArgument(position) }
            else { result.environment.invalidateAllArguments() }
            return [result]
        case .evaluate(let expression, let line):
            return bounded(evaluate(expression, state: state, graph: graph, depth: depth, line: callLine ?? line).map(\.state))
        case .newPage:
            flush(state)
            var result = state; result.page = []; result.line = 0
            return [result]
        case .forget(let names):
            var result = state; result.environment.forget(names); return [result]
        case .forgetAll:
            var result = state; result.environment = TextEnvironment(); return [result]
        default: return [state]
        }
    }

    private func evaluate(_ expression: TextExpression, state: FlowState, graph: ScriptGraph, depth: Int, line: Int) -> [FlowResult] {
        if state.stopped { return [.init(state: state, value: .unknown(expression.sourceText))] }
        switch expression {
        case .call(let rawName, let arguments, let source, _):
            return evaluateCall(rawName, arguments: arguments, source: source, state: state, graph: graph, depth: depth, line: line)
        case .choice(let condition, let yes, let no, _):
            var results: [FlowResult] = []
            for evaluated in evaluate(condition, state: state, graph: graph, depth: depth, line: line) {
                let value = evaluated.value.integer(in: evaluated.state.environment)
                if value != 0 { results += evaluate(yes, state: evaluated.state, graph: graph, depth: depth, line: line) }
                if value == nil || value == 0 { results += evaluate(no, state: evaluated.state, graph: graph, depth: depth, line: line) }
            }
            return boundResults(results)
        case .concatenate(let terms, let source):
            return evaluateTerms(terms, state: state, graph: graph, depth: depth, line: line) { values in
                if values.contains(where: { $0.isText(in: state.environment) }) { return .concatenate(values, source: source) }
                return .operation("+", values, source: source)
            }
        case .format(let terms, let source): return evaluateTerms(terms, state: state, graph: graph, depth: depth, line: line) { .format($0, source: source) }
        case .operation(let op, let terms, let source):
            if terms.count == 2, op == "&&" || op == "||" {
                var results: [FlowResult] = []
                for lhs in evaluate(terms[0], state: state, graph: graph, depth: depth, line: line) {
                    if let value = lhs.value.integer(in: lhs.state.environment), (op == "&&" && value == 0) || (op == "||" && value != 0) {
                        results.append(.init(state: lhs.state, value: .number(value == 0 ? 0 : 1, source: source)))
                    } else {
                        for rhs in evaluate(terms[1], state: lhs.state, graph: graph, depth: depth, line: line) {
                            results.append(.init(state: rhs.state, value: .operation(op, [lhs.value, rhs.value], source: source)))
                        }
                    }
                }
                return boundResults(results)
            }
            return evaluateTerms(terms, state: state, graph: graph, depth: depth, line: line) { .operation(op, $0, source: source) }
        default: return [.init(state: state, value: expression)]
        }
    }

    /// Keep call execution out of the recursive expression dispatcher. Debug builds otherwise
    /// reserve a large call-handling stack frame even for every term in a long concatenation.
    private func evaluateCall(_ rawName: String, arguments: [TextExpression], source: String,
                              state: FlowState, graph: ScriptGraph, depth: Int, line: Int) -> [FlowResult] {
        let name = rawName.lowercased()
        if name == "getarg" || name == "getargcount" || name == "getarraysize" {
            return [.init(state: state, value: .call(rawName, arguments, source: source, line: line))]
        }
        var candidates: [(FlowState, [TextExpression])] = [(state, [])]
        for argument in arguments {
            var after: [(FlowState, [TextExpression])] = []
            for (before, values) in candidates {
                for result in evaluate(argument, state: before, graph: graph, depth: depth, line: line) {
                    for (segments, environment) in result.state.environment.expansions(for: result.value) {
                        var next = result.state; next.environment = environment
                        after.append((next, values + [snapshot(result.value, segments: segments, environment: environment)]))
                    }
                }
            }
            candidates = boundCandidates(after)
        }
        var results: [FlowResult] = []
        for (before, values) in candidates {
            if before.stopped { results.append(.init(state: before, value: .unknown(source))); continue }
            if name == "select" || name == "prompt" {
                for value in values { options(value, state: before, line: line) }
                let texts = values.map { literal($0, environment: before.environment) }
                if texts.allSatisfy({ $0 != nil }) {
                    let entries = texts.compactMap { $0 }.flatMap { $0.split(separator: ":", omittingEmptySubsequences: false) }
                    var selections = entries.enumerated().filter { !$0.element.isEmpty }.map { $0.offset + 1 }
                    if name == "prompt" { selections.append(255) }
                    for selection in selections {
                        var selected = before
                        selected.environment.assign(TextReference(name: "@menu", index: nil, source: "@menu"),
                                                    values: [.number(selection, source: source)], append: false)
                        results.append(.init(state: selected, value: .number(selection, source: source)))
                    }
                } else { results.append(.init(state: before, value: .unknown(source))) }
                continue
            }
            var targets: [(ScriptGraph, Int, Bool)] = []
            var parameters = values
            var parameterExpressions = arguments
            if name == "callsub", let label = arguments.first?.sourceText {
                if let entry = graph.labels[label] { targets = [(graph, entry, false)] }
                else if var local = graph.functions[label] {
                    local.functions = graph.functions
                    targets = [(local, local.entry, false)]
                }
                parameters = Array(values.dropFirst())
                parameterExpressions = Array(arguments.dropFirst())
            } else if name == "callfunc" {
                if let first = values.first, let function = literal(first, environment: before.environment) {
                    targets = (library.functions[function] ?? []).map { ($0, $0.entry, true) }
                }
                parameters = Array(values.dropFirst())
                parameterExpressions = Array(arguments.dropFirst())
            } else if var local = graph.functions[rawName] {
                local.functions = graph.functions
                targets = [(local, local.entry, false)]
            } else {
                targets = (library.functions[rawName] ?? []).map { ($0, $0.entry, true) }
            }
            if !targets.isEmpty, depth < 8, remainingInstructions > 0 {
                for (targetGraph, entry, separateNPC) in targets {
                    var callee = before
                    callee.environment = before.environment.enteringCall(arguments: parameters, targets: parameterExpressions.map { before.environment.argumentTarget(for: $0) }, separateNPC: separateNPC)
                    for result in execute(targetGraph, entry: entry, state: callee, depth: depth + 1, callLine: line) {
                        var returned = result.state
                        let value = snapshot(result.value, environment: returned.environment)
                        returned.environment = returned.environment.returning(to: before.environment, separateNPC: separateNPC)
                        results.append(.init(state: returned, value: value))
                    }
                }
            } else {
                var result = before
                if name == "callfunc" || name == "callsub" || name.hasPrefix("f_") || !targets.isEmpty {
                    flush(result); result.page = []; result.line = 0
                    result.environment = TextEnvironment()
                }
                results.append(.init(state: result, value: .unknown(source)))
            }
        }
        return boundResults(results)
    }

    private func evaluateTerms(_ terms: [TextExpression], state: FlowState, graph: ScriptGraph, depth: Int, line: Int,
                               build: ([TextExpression]) -> TextExpression) -> [FlowResult] {
        var candidates: [(FlowState, [TextExpression])] = [(state, [])]
        for term in terms {
            var after: [(FlowState, [TextExpression])] = []
            for (before, values) in candidates {
                for result in evaluate(term, state: before, graph: graph, depth: depth, line: line) {
                    for (segments, environment) in result.state.environment.expansions(for: result.value) {
                        var next = result.state; next.environment = environment
                        after.append((next, values + [snapshot(result.value, segments: segments, environment: environment)]))
                    }
                }
            }
            candidates = boundCandidates(after)
        }
        return candidates.map { .init(state: $0.0, value: build($0.1)) }
    }

    private func snapshot(_ expression: TextExpression, segments: [Segment]? = nil, environment: TextEnvironment) -> TextExpression {
        if let value = expression.integer(in: environment) { return .number(value, source: expression.sourceText) }
        let variants = segments.map { [$0] } ?? expression.variants(in: environment)
        let expressions = variants.map { segments -> TextExpression in
            var terms: [TextExpression] = segments.map { segment in
                switch segment { case .literal(let value): return .literal(value); case .placeholder(let source): return .unknown(source) }
            }
            let containsLiteral = segments.contains { if case .literal = $0 { return true }; return false }
            if !containsLiteral {
                if expression.isText(in: environment) { terms.insert(.literal(""), at: 0) }
                else { return .unknown(expression.sourceText) }
            }
            return .concatenate(terms, source: expression.sourceText)
        }
        guard var result = expressions.first else { return .unknown(expression.sourceText) }
        for expression in expressions.dropFirst() { result = .choice(.unknown(""), result, expression, source: result.sourceText) }
        return result
    }

    private func literal(_ expression: TextExpression, environment: TextEnvironment) -> String? {
        let values = expression.variants(in: environment)
        guard values.count == 1 else { return nil }
        var result = ""
        for segment in values[0] { guard case .literal(let value) = segment else { return nil }; result += value }
        return result
    }

    private func options(_ expression: TextExpression, state: FlowState, line: Int) {
        for segments in expression.variants(in: state.environment) {
            var option: [Segment] = []
            func finish() {
                if let script = ExtractedScript(kind: .option, npc: npc, line: line, lines: [option]) { emit(script) }
                option = []
            }
            for segment in segments {
                switch segment {
                case .placeholder: option.append(segment)
                case .literal(let value):
                    for (index, piece) in value.split(separator: ":", omittingEmptySubsequences: false).enumerated() {
                        if index > 0 { finish() }
                        option.append(.literal(String(piece)))
                    }
                }
            }
            finish()
        }
    }

    private func alternatives(_ expressions: [TextExpression]) -> TextExpression {
        var unique: [TextExpression] = []
        for expression in expressions where !unique.contains(expression) { unique.append(expression) }
        guard var result = unique.first else { return .unknown("") }
        guard unique.count <= 16 else { return .unknown(result.sourceText) }
        for expression in unique.dropFirst() { result = .choice(.unknown(""), result, expression, source: result.sourceText) }
        return result
    }

    private func boundCandidates(_ candidates: [(FlowState, [TextExpression])]) -> [(FlowState, [TextExpression])] {
        guard candidates.count > 16 else { return candidates }
        for (state, _) in candidates { flush(state) }
        let active = candidates.filter { !$0.0.stopped }
        guard let first = active.first else { return [(FlowState(stopped: true), [])] }
        let state = FlowState(environment: .joined(active.map { $0.0.environment }))
        let values = first.1.indices.map { index in alternatives(active.compactMap { $0.1.indices.contains(index) ? $0.1[index] : nil }) }
        return [(state, values)]
    }

    private func boundResults(_ results: [FlowResult]) -> [FlowResult] {
        guard results.count > 16 else { return results }
        for result in results { flush(result.state) }
        let active = results.filter { !$0.state.stopped }
        guard !active.isEmpty else { return [.init(state: FlowState(stopped: true), value: .unknown(""))] }
        return [.init(state: FlowState(environment: .joined(active.map { $0.state.environment })), value: alternatives(active.map(\.value)))]
    }

    private func bounded(_ states: [FlowState]) -> [FlowState] {
        var unique: [FlowState] = []
        for state in states where !unique.contains(state) { unique.append(state) }
        guard unique.count > 16 else { return unique }
        for state in unique { flush(state) }
        let active = unique.filter { !$0.stopped }
        return active.isEmpty ? [FlowState(stopped: true)] : [FlowState(environment: .joined(active.map(\.environment)))]
    }

    private func flush(_ state: FlowState) {
        if let script = ExtractedScript(kind: .message, npc: npc, line: state.line, lines: state.page) { emit(script) }
    }
}
