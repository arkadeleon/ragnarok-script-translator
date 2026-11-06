//
//  TranslationPrompt.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/22.
//

import Foundation

/// Builds the instructions for a general-purpose instruction model. Terminology goes straight into
/// the prompt: an instruction model follows it, so no substitution tricks are needed.
enum TranslationPrompt {
    static func system(language: String, glossary: [Glossary.Entry], examples: [Glossary.Example]) -> String {
        let target = languageName(for: language)
        var prompt = """
        You translate NPC dialogue from the MMORPG Ragnarok Online from English into \(target).

        The input has "items" to translate, in the order they appear in the script. Each item has an \
        "npc", the NPC it belongs to (when known), and a "kind": "message" is one argument of a mes command, \
        "option" is one choice of a menu the player picks from. "context" holds the lines just before \
        the items, with their "translation" where one exists already: read it to follow the \
        conversation and keep names, tone and forms of address consistent with it, but do not \
        translate it or return it. Source order does not guarantee a continuous conversation: \
        nearby items may belong to different NPCs or alternative branches. Use context only where \
        it fits the current item.

        Rules:
        - Keep placeholders like {0}, {1} exactly as they are; they are substituted at runtime.
        - Keep color codes like ^FF0000 and ^000000 exactly where they are.
        - A speaker name in square brackets, like [Kafra Employee], may be an item on its own: translate the name and keep the brackets. Do not copy it into other items. If it is the first line of a longer item, keep it on its own first line. Keep [{0}] exactly as it is when it is the player's name.
        - Each message is sent separately to the client and may be a sentence fragment. Use context to understand it, but translate only that item; do not merge text across items or move text between them. Do not complete a fragment by adding missing words or turn every fragment into a full sentence. Keep blank lines and one-item-per-line lists as they are. The game wraps long lines itself.
        - Write ellipses as three half-width periods "...".
        - Do not add explanations or notes.
        - Options (kind "option") and item names are short; translate them as short labels, without adding a full stop.
        - Use the standard Ragnarok Online \(target) terminology.
        """
        if !glossary.isEmpty {
            prompt += """
            \n\nTerminology to use. Each entry says what kind of name it is; use it only where the text \
            refers to that thing. A name that is also an everyday word (a speaker called "Check", a job \
            called "Champion") is translated as the everyday word where it is used as one.\n
            """
            for entry in glossary {
                prompt += "- \(entry.term) (\(entry.kind)) = \(entry.translation)\n"
            }
        }
        if !examples.isEmpty {
            prompt += "\n\nExamples of terminology and tone (strings in JSON notation). Some examples show whole pages; they do not define item boundaries. Always translate each actual input item separately:\n"
            for example in examples {
                prompt += "\n\(example.kind.rawValue): \(jsonString(example.text))\n=> \(jsonString(example.translation))\n"
            }
        }
        prompt += "\nReturn JSON: {\"translations\":[{\"id\": ..., \"text\": ...}, ...]} with one entry per input id, in the same order."
        return prompt
    }

    private static func jsonString(_ string: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? String(decoding: encoder.encode(string), as: UTF8.self)) ?? string
    }

    private static let languageNames: [String: String] = [
        "zh-Hans": "Simplified Chinese",
        "zh-Hant": "Traditional Chinese",
        "ja": "Japanese",
        "ko": "Korean",
        "de": "German",
        "fr": "French",
        "es": "Spanish",
        "pt-BR": "Brazilian Portuguese",
        "th": "Thai",
        "id": "Indonesian",
        "tr": "Turkish",
        "ru": "Russian",
    ]

    static func languageName(for code: String) -> String {
        if let name = languageNames[code] {
            return name
        }
        return Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
    }
}
