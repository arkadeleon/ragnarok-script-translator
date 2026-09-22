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
    static func system(language: String, glossary: [(term: String, translation: String)], names: [(term: String, translation: String)]) -> String {
        let target = languageName(for: language)
        var prompt = """
        You translate NPC dialogue from the MMORPG Ragnarok Online from English into \(target).

        Rules:
        - Keep placeholders like {0}, {1} exactly as they are; they are substituted at runtime.
        - Keep color codes like ^FF0000 and ^000000 exactly where they are.
        - The "speaker" field says who is talking; it is context only. Never add a speaker line or name to the text.
        - The source is hard-wrapped for a narrow English text box. Join its lines into natural sentences and break lines only where a sentence ends; keep blank lines and one-item-per-line lists as they are. The game wraps long lines itself.
        - Do not add explanations or notes.
        - Menu options and item names are short; translate them as short labels, without adding a full stop.
        - Use the standard Ragnarok Online \(target) terminology.
        """
        if !names.isEmpty {
            prompt += "\n\nCharacter names, exactly as translated elsewhere:\n"
            for entry in names {
                prompt += "- \(entry.term) = \(entry.translation)\n"
            }
        }
        if !glossary.isEmpty {
            prompt += "\n\nTerminology to use:\n"
            for entry in glossary {
                prompt += "- \(entry.term) = \(entry.translation)\n"
            }
        }
        prompt += "\nReturn JSON: {\"translations\":[{\"id\": ..., \"text\": ...}, ...]} with one entry per input id, in the same order."
        return prompt
    }

    /// For the names that head dialogue pages: short, consistent, no commentary.
    static func speakers(language: String, glossary: [(term: String, translation: String)], examples: [(term: String, translation: String)]) -> String {
        let target = languageName(for: language)
        var prompt = """
        You translate the names of NPC speakers in the MMORPG Ragnarok Online from English into \(target).
        Each item is a name as shown above a dialogue box, such as "Kafra Employee", "Prontera Guard" or "Shuger".

        Rules:
        - Translate titles and descriptions ("Guard", "Employee").
        - Write every personal name in \(target), the way the official \(target) Ragnarok Online client does. Invented and unfamiliar names are transliterated by sound; never copy the Latin spelling, and never leave one item in English because the previous one looked unusual.
        - Keep placeholders like {0} exactly as they are; they stand for the player's name.
        - Return only the name: one line, no brackets, no explanation.
        - Use the standard Ragnarok Online \(target) terminology.
        """
        if !examples.isEmpty {
            prompt += "\n\nNames are written in \(target) like these:\n"
            for entry in examples {
                prompt += "- \(entry.term) = \(entry.translation)\n"
            }
        }
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
