//
//  ScriptExtractor.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/21.
//

/// Collects one message per `mes` argument, matching the server's dialog packets,
/// plus individual menu options. Branches and loops are visited once in source order.
struct ScriptExtractor {
    private let tokens: [Token]
    private let parser: ScriptParser

    init(source: String) {
        var tokenizer = ScriptTokenizer(source: source)
        tokens = tokenizer.tokenize()

        let bytes = Array(source.utf8)
        parser = ScriptParser(source: bytes, tokens: tokens)
    }

    func extract() -> [ExtractedScript] {
        var scripts: [ExtractedScript] = []
        func append(_ script: ExtractedScript) {
            scripts.append(script)
        }

        var parser = self.parser
        let parsedScripts = parser.parseScripts()

        for script in parsedScripts {
            extractMessages(from: .block(script.statements), npc: script.npc, into: append)
        }

        extractOptions(into: append)

        // Preserve argument order for messages on the same source line.
        return scripts.enumerated()
            .sorted { ($0.element.line, $0.offset) < ($1.element.line, $1.offset) }
            .map(\.element)
    }

    private func extractMessages(from statement: Statement, npc: String?, into append: (ExtractedScript) -> Void) {
        switch statement {
        case .mes(let lines):
            for line in lines {
                if let message = ExtractedScript(kind: .message, npc: npc, line: line.line, lines: [line.segments]) {
                    append(message)
                }
            }
        case .block(let statements):
            for statement in statements {
                extractMessages(from: statement, npc: npc, into: append)
            }
        case .branch(let alternatives, let otherwise):
            for alternative in alternatives {
                extractMessages(from: alternative, npc: npc, into: append)
            }
            if let otherwise {
                extractMessages(from: otherwise, npc: npc, into: append)
            }
        case .switch(let cases, _):
            for body in cases {
                extractMessages(from: body, npc: npc, into: append)
            }
        case .loop(let body):
            extractMessages(from: body, npc: npc, into: append)
        case .transparent, .newPage, .terminate, .exit, .label:
            break
        }
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
                makeOptions(npc: npc, line: token.line, arguments: arguments).forEach(append)
                index = end
            case "menu":
                let (arguments, end) = parser.parseArguments(from: index + 1, until: ";")
                // `menu "text",L_label,"text",L_label,...`: every other argument is a label.
                let texts = arguments.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
                makeOptions(npc: npc, line: token.line, arguments: texts).forEach(append)
                index = end
            default:
                index += 1
            }
        }
    }

    /// Menu arguments may hold several options separated by `:`; empty options are hidden by the client.
    private func makeOptions(npc: String?, line: Int, arguments: [[Segment]]) -> [ExtractedScript] {
        var options: [ExtractedScript] = []
        for argument in arguments {
            var current: [Segment] = []
            func finishOption() {
                if let option = ExtractedScript(kind: .option, npc: npc, line: line, lines: [current]) {
                    options.append(option)
                }
                current.removeAll()
            }
            for (segmentIndex, segment) in argument.enumerated() {
                switch segment {
                case .placeholder(let expression):
                    // `select(.@menu$ + "Cancel")`: the variable holds a `:`-terminated list of options
                    // built elsewhere, so the literal after it is an option of its own.
                    if segmentIndex == 0, expression.lowercased().hasSuffix("menu$") {
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
}
