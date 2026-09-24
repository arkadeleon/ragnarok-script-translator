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
        "npc", the NPC it belongs to (when known), and a "kind": "message" is a page of dialogue, \
        "option" is one choice of a menu the player picks from. "context" holds the lines just before \
        the items, with their "translation" where one exists already: read it to follow the \
        conversation and keep names, tone and forms of address consistent with it, but do not \
        translate it or return it.

        Rules:
        - Keep placeholders like {0}, {1} exactly as they are; they are substituted at runtime.
        - Keep color codes like ^FF0000 and ^000000 exactly where they are.
        - A first line in square brackets, like [Kafra Employee], is the speaker's name: translate the name, keep the brackets and keep it on its own first line. A first line of exactly [{0}] is the player's own name: keep it exactly as it is.
        - The source is hard-wrapped for a narrow English text box. Join its lines into natural sentences and break lines only where a sentence ends; keep blank lines and one-item-per-line lists as they are. The game wraps long lines itself.
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
            prompt += "\n\nExamples of the expected style (strings in JSON notation):\n"
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
