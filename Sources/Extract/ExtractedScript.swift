//
//  ExtractedScript.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/21.
//

/// All translatable scripts found in one rAthena NPC file.
struct ExtractedFile: Codable {
    /// Path relative to the swift-rathena checkout, e.g. `npc/cities/prontera.txt`.
    var file: String
    var scripts: [ExtractedScript]
}

/// One unit of text the client looks up at runtime: a page of dialog or a single menu option.
struct ExtractedScript: Codable {
    enum Kind: String, Codable {
        /// Consecutive `mes` lines shown together, joined by `\n`.
        case message
        /// One entry of a `select`, `prompt` or `menu`.
        case option
    }

    var kind: ExtractedScript.Kind

    /// Display name of the NPC the script belongs to, if known.
    var npc: String?

    /// Line in the source file where the script starts.
    var line: Int

    /// The text as the server sends it, with non-literal parts replaced by `{0}`, `{1}`, ...
    var text: String

    /// Source expressions for each placeholder, in order.
    var placeholders: [String]?

    init(kind: ExtractedScript.Kind, npc: String?, line: Int, text: String, placeholders: [String]?) {
        self.kind = kind
        self.npc = npc
        self.line = line
        self.text = text
        self.placeholders = placeholders
    }

    init?(kind: ExtractedScript.Kind, npc: String?, line: Int, lines: [[Segment]]) {
        guard !lines.isEmpty else {
            return nil
        }

        var text = ""
        var placeholders: [String] = []
        var hasText = false

        for (lineIndex, segments) in lines.enumerated() {
            if lineIndex > 0 {
                text += "\n"
            }
            for segment in segments {
                switch segment {
                case .literal(let literal):
                    text += literal
                    if !literal.allSatisfy(\.isWhitespace) {
                        hasText = true
                    }
                case .placeholder(let expression):
                    text += "{\(placeholders.count)}"
                    placeholders.append(expression)
                }
            }
        }

        guard hasText else {
            return nil
        }

        self.init(kind: kind, npc: npc, line: line, text: text, placeholders: placeholders.isEmpty ? nil : placeholders)
    }
}
