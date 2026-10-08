//
//  GenerateGlossary.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/22.
//

import ArgumentParser
import Foundation

/// Builds `Glossary/<language>.lproj/Glossary.json` for every language ragnarok-data-converter ships,
/// from the item, map, monster and skill names in its `Output/` tables, grouped by that kind. The glossary is fed to the
/// translation model as terminology, so it only needs names whose official rendering the model
/// could not guess.
struct GenerateGlossary: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "glossary",
        abstract: "Fetches ragnarok-data-converter and generates a terminology glossary per language from item, map, monster and skill names."
    )

    @Option(name: .shortAndLong, help: "Directory to write <language>.lproj/Glossary.json into.")
    var output: String = "Glossary"

    private struct ItemInfo: Decodable {
        var identifiedItemName: String?
    }

    private struct MapInfo: Decodable {
        var signMainTitle: String?
    }

    private struct SkillInfo: Decodable {
        var skillName: String?
    }

    /// Clients whose tables are not localized (English names, or English variants with stray
    /// Korean); what survives the filters is only misleading.
    private static let skippedLanguages: Set<String> = ["de", "fr", "id", "th", "tr"]

    /// (English, translation, isProperName): proper names skip the everyday-word filter.
    private typealias Pair = (term: String, translation: String, isProperName: Bool)

    func run() throws {
        let repositoryURL = URL(filePath: "ragnarok-data-converter")
        try Git.sync(repository: repositoryURL, from: "https://github.com/arkadeleon/ragnarok-data-converter.git")

        let dataURL = repositoryURL.appending(path: "Output")
        let english = dataURL.appending(path: "en.lproj")
        let monsterNames = try rathenaMonsterNames()

        let items = try load([String: ItemInfo].self, english.appending(path: "ItemInfo.json"))
        let maps = try load([String: MapInfo].self, english.appending(path: "MapInfo.json"))
        let skills = try load([String: SkillInfo].self, english.appending(path: "SkillInfo.json"))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        for language in try languages(in: dataURL) {
            if Self.skippedLanguages.contains(language) {
                print("\(language): skipped (tables are not localized)")
                continue
            }
            let target = dataURL.appending(path: "\(language).lproj")
            // Kept apart per kind: the prompt names the kind, and a name shared by an item and a
            // skill ("Fire Arrow") keeps both renderings.
            var glossary: [String: [String: String]] = [:]

            if let targetMaps = try? load([String: MapInfo].self, target.appending(path: "MapInfo.json")) {
                let pairs = maps.compactMap { id, map -> Pair? in
                    guard let name = map.signMainTitle, let translated = targetMaps[id]?.signMainTitle else {
                        return nil
                    }
                    return (name, translated, true)
                }
                glossary["map"] = select(pairs, language: language)
            }
            if let targetMonsters = try? load([String: String].self, target.appending(path: "MonsterName.json")) {
                let pairs = monsterNames.compactMap { id, name -> Pair? in
                    guard let translated = targetMonsters[String(format: "%05d", id)] else {
                        return nil
                    }
                    return (name, translated, true)
                }
                glossary["monster"] = select(pairs, language: language)
            }
            if let targetItems = try? load([String: ItemInfo].self, target.appending(path: "ItemInfo.json")) {
                let pairs = items.compactMap { id, item -> Pair? in
                    guard let name = item.identifiedItemName, let translated = targetItems[id]?.identifiedItemName else {
                        return nil
                    }
                    return (name, translated, false)
                }
                glossary["item"] = select(pairs, language: language)
            }
            // Skill names are proper names even when they are everyday words ("Heal", "Cure").
            if let targetSkills = try? load([String: SkillInfo].self, target.appending(path: "SkillInfo.json")) {
                let pairs = skills.compactMap { id, skill -> Pair? in
                    guard let name = skill.skillName, let translated = targetSkills[id]?.skillName else {
                        return nil
                    }
                    return (name, translated, true)
                }
                glossary["skill"] = select(pairs, language: language)
            }

            let glossaryURL = URL(filePath: output).appending(path: "\(language).lproj").appending(path: "Glossary.json")
            try FileManager.default.createDirectory(at: glossaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(glossary).write(to: glossaryURL, options: .atomic)
            print("\(language): \(glossary.values.map(\.count).reduce(0, +)) terms")
        }
    }

    // MARK: - Selection

    private enum Script: CaseIterable {
        case han, kana, hangul, thai, cyrillic

        /// Scripts a translation must use for each non-Latin language. Anything in another script is
        /// an untranslated or leaked entry (English left as is, Korean in a Thai table, mojibake).
        static let scriptsByLanguage: [String: [Script]] = [
            "zh-Hans": [.han],
            "zh-Hant": [.han],
            "ja": [.kana, .han],
            "ko": [.hangul],
            "th": [.thai],
            "ru": [.cyrillic],
        ]

        func contains(_ scalar: Unicode.Scalar) -> Bool {
            switch (self, scalar.value) {
            case (.han, 0x3400...0x4DBF), (.han, 0x4E00...0x9FFF): true
            case (.kana, 0x3040...0x30FF): true
            case (.hangul, 0x1100...0x11FF), (.hangul, 0x3130...0x318F), (.hangul, 0xAC00...0xD7AF): true
            case (.thai, 0x0E00...0x0E7F): true
            case (.cyrillic, 0x0400...0x04FF): true
            default: false
            }
        }
    }

    /// True when `translation` is written in the target language's script and nothing else.
    private func isInScript(_ translation: String, of language: String) -> Bool {
        let scalars = translation.unicodeScalars.filter { $0.properties.isAlphabetic }
        if let expected = Script.scriptsByLanguage[language] {
            let inScript = scalars.filter { scalar in
                expected.contains { $0.contains(scalar) }
            }
            let foreign = scalars.filter { scalar in
                Script.allCases.contains { $0.contains(scalar) } && !expected.contains { $0.contains(scalar) }
            }
            return !inScript.isEmpty && foreign.isEmpty
        }
        // Latin-script language: nothing from the other scripts, and no identifiers.
        return !scalars.contains { scalar in Script.allCases.contains { $0.contains(scalar) } } && !translation.contains("_")
    }

    /// Keeps the pairs that make useful terminology: names with an official rendering that differs
    /// from the English, excluding everyday words that are only incidentally item names and
    /// "translations" that are merely another English spelling of the same name.
    private func select(_ pairs: [Pair], language: String) -> [String: String] {
        let dictionaryWords = self.dictionaryWords()
        var votes: [String: [String: Int]] = [:]

        for (term, translation, isProperName) in pairs {
            let term = term.trimmingCharacters(in: .whitespaces)
            let translation = translation.trimmingCharacters(in: .whitespaces)
            guard term != translation,
                  term.count >= 3, !translation.isEmpty,
                  let first = term.first, first.isLetter,
                  !term.contains("{"), !term.contains("("), !term.contains("["), !term.contains("<"),
                  term != "Unknown Item" else {
                continue
            }
            // A single everyday word ("Apple", "Milk", "Staff") is more likely prose than an item.
            if !isProperName, !term.contains(" "), dictionaryWords.contains(term.lowercased()) {
                continue
            }
            if translation.allSatisfy(\.isNumber) || translation.isMojibake
                || !isInScript(translation, of: language) || isRespelling(term, translation) {
                continue
            }
            votes[term, default: [:]][translation, default: 0] += 1
        }

        var glossary: [String: String] = [:]
        for (term, translations) in votes {
            glossary[term] = translations.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }!.key
        }
        return glossary
    }

    /// "Fine Dry Sand" -> "Dry Sand", "Red_Potion" -> "Red Potion": the same English words rearranged.
    private func isRespelling(_ term: String, _ translation: String) -> Bool {
        let termWords = term.words
        let translationWords = translation.words
        guard !termWords.isEmpty, !translationWords.isEmpty else {
            return false
        }
        let shared = termWords.intersection(translationWords).count
        return shared * 2 >= min(termWords.count, translationWords.count)
    }

    private func dictionaryWords() -> Set<String> {
        guard let contents = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else {
            return []
        }
        return Set(contents.split(separator: "\n").map { $0.lowercased() })
    }

    // MARK: - Loading

    private func load<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: data)
    }

    /// Every `<language>.lproj` in the converter output except English.
    private func languages(in dataURL: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dataURL.path)
            .filter { $0.hasSuffix(".lproj") && $0 != "en.lproj" }
            .map { String($0.dropLast(".lproj".count)) }
            .sorted()
    }

    /// English monster names from swift-rathena's `db/re/mob_db.yml`; the converter has none.
    /// A line-based scan is enough for that layout. Empty if the checkout is absent.
    private func rathenaMonsterNames() throws -> [(Int, String)] {
        let url = URL(filePath: "swift-rathena/db/re/mob_db.yml")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        var names: [(Int, String)] = []
        var currentID: Int?
        for line in contents.split(separator: "\n") {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("- Id: "), let id = Int(trimmedLine.dropFirst("- Id: ".count)) {
                currentID = id
            } else if trimmedLine.hasPrefix("Name: "), let id = currentID {
                let name = String(trimmedLine.dropFirst("Name: ".count)).trimmingCharacters(in: .whitespaces)
                names.append((id, name))
                currentID = nil
            }
        }
        return names
    }
}

extension String {
    /// Korean bytes read as Latin-1 ("ÀÇ»ó Á×À½") show up as Latin-1 symbols and C1 controls,
    /// which no real translation contains.
    fileprivate var isMojibake: Bool {
        unicodeScalars.contains { scalar in
            (0x80...0xBF).contains(scalar.value) || scalar.value == 0xD7 || scalar.value == 0xF7
        }
    }

    fileprivate var words: Set<String> {
        Set(lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }
}
