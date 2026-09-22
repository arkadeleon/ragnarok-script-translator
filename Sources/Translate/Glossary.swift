//
//  Glossary.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/22.
//

import Foundation

/// Terminology from `Glossary/<language>.lproj/Glossary.json` (see the `glossary` command):
/// `{ "Red Potion": "红色药水", ... }`. Only the terms that occur in a batch are put into its prompt.
struct Glossary {
    private var entries: [(term: String, translation: String)] = []

    var count: Int { entries.count }

    init() {}

    /// An ad-hoc glossary, e.g. the speaker names of one file.
    init(terms: [String: String]) {
        entries = terms.map { (term: $0.key, translation: $0.value) }.sorted { $0.term < $1.term }
    }

    init(directory: URL, language: String) throws {
        let url = directory.appending(path: "\(language).lproj").appending(path: "Glossary.json")
        guard let data = try? Data(contentsOf: url) else {
            return
        }
        let dictionary = try JSONDecoder().decode([String: String].self, from: data)
        entries = dictionary.map { (term: $0.key, translation: $0.value) }.sorted { $0.term < $1.term }
    }

    /// A few single-word proper nouns with their official rendering, to show the model how names
    /// are written in the target language. Preferred ones first, then whatever the glossary has.
    func nameExamples(count: Int) -> [(term: String, translation: String)] {
        let preferred = ["Poring", "Prontera", "Geffen", "Payon", "Kafra", "Izlude"]
        var examples = entries.filter { preferred.contains($0.term) }
        for entry in entries where examples.count < count {
            let isSingleWord = !entry.term.contains(" ") && entry.term.allSatisfy { $0.isLetter }
            if isSingleWord, entry.term.count >= 4, !examples.contains(where: { $0.term == entry.term }) {
                examples.append(entry)
            }
        }
        return Array(examples.prefix(count))
    }

    func entries(in texts: [String]) -> [(term: String, translation: String)] {
        entries.filter { entry in
            texts.contains { Self.contains($0, word: entry.term) }
        }
    }

    /// Whole-word, case-sensitive match; an `s` after the term still counts.
    private static func contains(_ text: String, word: String) -> Bool {
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: word, range: searchRange) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            var after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if after == "s" {
                let next = text.index(after: range.upperBound)
                after = next == text.endIndex ? nil : text[next]
            }
            if !(before?.isLetter ?? false), !(before?.isNumber ?? false), !(after?.isLetter ?? false), !(after?.isNumber ?? false) {
                return true
            }
            searchRange = range.upperBound..<text.endIndex
        }
        return false
    }
}
