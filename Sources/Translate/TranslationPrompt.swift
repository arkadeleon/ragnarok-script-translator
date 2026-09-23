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
    static func system(language: String, glossary: [(term: String, translation: String)]) -> String {
        let target = languageName(for: language)
        var prompt = """
        You translate NPC dialogue from the MMORPG Ragnarok Online from English into \(target).

        Rules:
        - Keep placeholders like {0}, {1} exactly as they are; they are substituted at runtime.
        - Keep color codes like ^FF0000 and ^000000 exactly where they are.
        - A first line in square brackets, like [Kafra Employee], is the speaker's name: translate the name, keep the brackets and keep it on its own first line. A first line of exactly [{0}] is the player's own name: keep it exactly as it is.
        - The source is hard-wrapped for a narrow English text box. Join its lines into natural sentences and break lines only where a sentence ends; keep blank lines and one-item-per-line lists as they are. The game wraps long lines itself.
        - Do not add explanations or notes.
        - Menu options and item names are short; translate them as short labels, without adding a full stop.
        - Use the standard Ragnarok Online \(target) terminology.
        """
        if !glossary.isEmpty {
            prompt += "\n\nTerminology to use:\n"
            for entry in glossary {
                prompt += "- \(entry.term) = \(entry.translation)\n"
            }
        }
        prompt += "\nReturn JSON: {\"translations\":[{\"id\": ..., \"text\": ...}, ...]} with one entry per input id, in the same order."
        return prompt
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
