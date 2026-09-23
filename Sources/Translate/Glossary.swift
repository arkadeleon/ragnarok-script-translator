//
//  Glossary.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/22.
//

import Foundation

/// Terminology from `Glossary/<language>.lproj/`: `Glossary.json` is generated from the game data
/// tables by the `glossary` command, `Manual.json` is maintained by hand for the terms those tables
/// do not carry (zeny, job names, Kafra, ...) and wins on conflict. Only the terms that occur in a
/// batch are put into its prompt.
struct Glossary {
    private var entries: [(term: String, translation: String)] = []

    var count: Int { entries.count }

    init() {}

    init(directory: URL, language: String) throws {
        let localized = directory.appending(path: "\(language).lproj")
        let decoder = JSONDecoder()
        var terms: [String: String] = [:]
        for name in ["Glossary.json", "Manual.json"] {
            guard let data = try? Data(contentsOf: localized.appending(path: name)) else {
                continue
            }
            terms.merge(try decoder.decode([String: String].self, from: data)) { _, later in later }
        }
        entries = terms.map { (term: $0.key, translation: $0.value) }.sorted { $0.term < $1.term }
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
