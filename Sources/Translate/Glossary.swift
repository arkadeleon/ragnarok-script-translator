//
//  Glossary.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/22.
//

import Foundation

/// Terminology from `Glossary/<language>.lproj/`: `Items.json`, `Maps.json`, `Monsters.json` and
/// `Skills.json` are generated from the game data tables by the `glossary` command, `Manual.json` is
/// maintained by hand for the terms those tables do not carry (zeny, job names, speaker names, ...)
/// and wins on conflict. Only the terms that occur in a batch are put into its prompt.
/// `Examples.json`, also by hand, holds a few translated lines that go into every prompt to show
/// the style.
///
/// Terms are grouped by kind: each generated file holds one kind (`{"Poring": "波利"}`), while
/// `Manual.json` groups its terms by kind (`{"monster": {...}, "job": {...}}`). The kind goes into
/// the prompt so the model can tell a name from the everyday word it happens to spell: a speaker
/// called "Check" is no reason to translate "check the forest" as its name.
struct Glossary {
    struct Entry {
        var term: String
        var kind: String
        var translation: String
    }

    /// A translated line shown to the model as an example.
    struct Example: Decodable {
        var kind: ExtractedScript.Kind
        var text: String
        var translation: String
    }

    private(set) var entries: [Glossary.Entry] = []
    private(set) var examples: [Glossary.Example] = []

    init(directory: URL, language: String) throws {
        let localized = directory.appending(path: "\(language).lproj")
        let decoder = JSONDecoder()
        func load(_ name: String) throws -> [Glossary.Entry] {
            guard let data = try? Data(contentsOf: localized.appending(path: name)) else {
                return []
            }
            return try decoder.decode([String: [String: String]].self, from: data).flatMap { kind, terms in
                terms.map { Glossary.Entry(term: $0.key, kind: kind, translation: $0.value) }
            }
        }
        func load(_ name: String, kind: String) throws -> [Glossary.Entry] {
            guard let data = try? Data(contentsOf: localized.appending(path: name)) else {
                return []
            }
            return try decoder.decode([String: String].self, from: data).map {
                Glossary.Entry(term: $0.key, kind: kind, translation: $0.value)
            }
        }
        let manual = try load("Manual.json")
        let manualTerms = Set(manual.map { $0.term.lowercased() })
        let generated = try [
            load("Items.json", kind: "item"),
            load("Monsters.json", kind: "monster"),
            load("Skills.json", kind: "skill"),
            load("Maps.json", kind: "map"),
        ]
        .joined()
        .filter { !manualTerms.contains($0.term.lowercased()) }
        // Matching ignores case, so "Old Man" and "Old man" with the same rendering are one entry.
        var seen: Set<[String]> = []
        entries = (generated + manual)
            .sorted { ($0.term, $0.kind) < ($1.term, $1.kind) }
            .filter { seen.insert([$0.term.lowercased(), $0.kind, $0.translation]).inserted }

        if let data = try? Data(contentsOf: localized.appending(path: "Examples.json")) {
            examples = try decoder.decode([Glossary.Example].self, from: data)
        }
    }

    func entries(in texts: [String]) -> [Glossary.Entry] {
        // Color codes sit right against the term (`^000077Poporing`) and would hide it.
        let texts = texts.map { $0.replacing(/\^[0-9A-Fa-f]{6}/, with: " ") }
        return entries.filter { entry in
            texts.contains { $0.contains(word: entry.term) }
        }
    }
}

extension String {
    /// Whole-word, case-insensitive match (scripts write `Al de Baran` for `Al De Baran`, or shout
    /// `MAGNUM BREAK!`); an `s` after the term still counts.
    fileprivate func contains(word: String) -> Bool {
        let text = self
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: word, options: .caseInsensitive, range: searchRange) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            var after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if after == "s" || after == "S" {
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
