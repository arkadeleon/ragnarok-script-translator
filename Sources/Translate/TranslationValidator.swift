//
//  TranslationValidator.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/21.
//

import Foundation

/// Checks that a translation still works as a client lookup value: the parts the client substitutes
/// or renders specially must survive untouched.
enum TranslationValidator {
    private static var placeholderPattern: Regex<Substring> { /\{\d+\}/ }
    private static var colorPattern: Regex<Substring> { /\^[0-9A-Fa-f]{6}/ }
    private static var headerPattern: Regex<(Substring, Substring)> { /^\[[^\]\n]*\](\n|$)/ }

    /// Returns a reason the translation is unacceptable, or nil if it passes.
    static func validate(source: String, translation: String) -> String? {
        if translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "empty"
        }

        let sourcePlaceholders = source.matches(of: placeholderPattern).map { String($0.output) }.sorted()
        let translationPlaceholders = translation.matches(of: placeholderPattern).map { String($0.output) }.sorted()
        if sourcePlaceholders != translationPlaceholders {
            return "placeholders changed: \(sourcePlaceholders) -> \(translationPlaceholders)"
        }

        let sourceColors = source.matches(of: colorPattern).count
        let translationColors = translation.matches(of: colorPattern).count
        if sourceColors != translationColors {
            return "color codes changed: \(sourceColors) -> \(translationColors)"
        }

        let sourceHasHeader = source.firstMatch(of: headerPattern) != nil
        let translationHasHeader = translation.firstMatch(of: headerPattern) != nil
        if sourceHasHeader, !translationHasHeader {
            return "speaker header lost"
        }
        if !sourceHasHeader, translationHasHeader {
            return "speaker header added"
        }
        if source.hasPrefix("[{0}]"), !translation.hasPrefix("[{0}]") {
            return "player name header changed"
        }

        for fragment in ["\");", "\\", "```"] where translation.contains(fragment) && !source.contains(fragment) {
            return "contains code fragment \(fragment)"
        }

        return nil
    }

    /// A speaker name must come back as one short line, not an explanation of one.
    static func validateSpeaker(source: String, translation: String) -> String? {
        if let reason = validate(source: source, translation: translation) {
            return reason
        }
        if translation.contains("\n") || translation.contains("[") || translation.contains("]") {
            return "not a single name"
        }
        for bracket in ["(", "（"] where translation.contains(bracket) && !source.contains(bracket) {
            return "contains commentary"
        }
        if translation.count > max(source.count * 3, 12) {
            return "too long for a name"
        }
        return nil
    }

    /// Repairs mistakes that are unambiguous: a literal backslash-n where the model meant a line break.
    static func tidy(_ translation: String, source: String) -> String {
        var result = translation
        if !source.contains("\\n") {
            result = result.replacingOccurrences(of: "\\n", with: "\n")
        }
        return result
    }
}
