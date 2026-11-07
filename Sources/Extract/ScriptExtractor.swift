//
//  ScriptExtractor.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/21.
//

/// Collects runtime dialog pages and menu options using bounded control-flow execution.
struct ScriptExtractor {
    let scripts: [ParsedScript]

    init(source: String) {
        var tokenizer = ScriptTokenizer(source: source)
        var parser = ScriptParser(source: Array(source.utf8), tokens: tokenizer.tokenize())
        scripts = parser.parseScripts()
    }

    func extract(library: ScriptLibrary? = nil) -> [ExtractedScript] {
        var library = library ?? ScriptLibrary(scripts: scripts)
        // Definitions in this file take precedence over alternative re/pre-re definitions.
        for script in scripts where script.isFunction {
            library.functions[script.name] = [ScriptGraph(.block(script.statements))]
        }
        var output: [ExtractedScript] = []
        var emitted: Set<[String]> = []
        for script in scripts {
            let interpreter = ScriptFlowInterpreter(library: library, npc: script.npc) { text in
                let key = [text.kind.rawValue, String(text.line), text.text] + (text.placeholders ?? [])
                if emitted.insert(key).inserted { output.append(text) }
            }
            interpreter.run(ScriptGraph(.block(script.statements)))
        }
        return output.enumerated().sorted { ($0.element.line, $0.offset) < ($1.element.line, $1.offset) }.map(\.element)
    }
}
