//
//  GenerateGlossary.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/22.
//

import ArgumentParser
import Foundation

/// Builds `Glossary/<language>.lproj/Glossary.json` for every language ragnarok-data-converter ships,
/// from the item, map and monster names in its `Output/` tables. The glossary is fed to the
/// translation model as terminology, so it only needs names whose official rendering the model
/// could not guess.
struct GenerateGlossary: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "glossary",
        abstract: "Fetches ragnarok-data-converter and generates a terminology glossary per language from item, map and monster names."
    )

    @Option(name: .shortAndLong, help: "Directory to write <language>.lproj/Glossary.json into.")
    var output: String = "Glossary"

    private struct ItemInfo: Decodable {
        var identifiedItemName: String?
    }

    private struct MapInfo: Decodable {
        var signMainTitle: String?
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
        let monsterNames = try Self.rathenaMonsterNames()

        let items = try Self.load([String: ItemInfo].self, english.appending(path: "ItemInfo.json"))
        let maps = try Self.load([String: MapInfo].self, english.appending(path: "MapInfo.json"))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        for language in try Self.languages(in: dataURL) {
            if Self.skippedLanguages.contains(language) {
                print("\(language): skipped (tables are not localized)")
                continue
            }
            let target = dataURL.appending(path: "\(language).lproj")
            var pairs: [Pair] = []

            if let targetMaps = try? Self.load([String: MapInfo].self, target.appending(path: "MapInfo.json")) {
                for (id, map) in maps {
                    if let name = map.signMainTitle, let translated = targetMaps[id]?.signMainTitle {
                        pairs.append((name, translated, true))
                    }
                }
            }
            if let targetMonsters = try? Self.load([String: String].self, target.appending(path: "MonsterName.json")) {
                for (id, name) in monsterNames {
                    if let translated = targetMonsters[String(format: "%05d", id)] {
                        pairs.append((name, translated, true))
                    }
                }
            }
            if let targetItems = try? Self.load([String: ItemInfo].self, target.appending(path: "ItemInfo.json")) {
                for (id, item) in items {
                    if let name = item.identifiedItemName, let translated = targetItems[id]?.identifiedItemName {
                        pairs.append((name, translated, false))
                    }
                }
            }

            let glossary = Self.select(pairs, language: language)
            let glossaryURL = URL(filePath: output).appending(path: "\(language).lproj").appending(path: "Glossary.json")
            try FileManager.default.createDirectory(at: glossaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(glossary).write(to: glossaryURL, options: .atomic)
            print("\(language): \(glossary.count) terms")
        }
    }

    // MARK: - Selection

    private enum Script {
        case han, kana, hangul, thai, cyrillic

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

    /// Scripts a translation must use for each non-Latin language. Anything in another script is
    /// an untranslated or leaked entry (English left as is, Korean in a Thai table, mojibake).
    private static let scripts: [String: [Script]] = [
        "zh-Hans": [.han], "zh-Hant": [.han], "ja": [.kana, .han], "ko": [.hangul], "th": [.thai], "ru": [.cyrillic],
    ]
    private static let allScripts: [Script] = [.han, .kana, .hangul, .thai, .cyrillic]

    /// True when `translation` is written in the target language's script and nothing else.
    private static func isInScript(_ translation: String, of language: String) -> Bool {
        let scalars = translation.unicodeScalars.filter { $0.properties.isAlphabetic }
        if let expected = scripts[language] {
            let inScript = scalars.filter { scalar in expected.contains { $0.contains(scalar) } }
            let foreign = scalars.filter { scalar in allScripts.contains { $0.contains(scalar) } && !expected.contains { $0.contains(scalar) } }
            return !inScript.isEmpty && foreign.isEmpty
        }
        // Latin-script language: nothing from the other scripts, and no identifiers.
        return !scalars.contains { scalar in allScripts.contains { $0.contains(scalar) } } && !translation.contains("_")
    }

    /// Keeps the pairs that make useful terminology: names with an official rendering that differs
    /// from the English, excluding everyday words that are only incidentally item names and
    /// "translations" that are merely another English spelling of the same name.
    private static func select(_ pairs: [Pair], language: String) -> [String: String] {
        let dictionaryWords = Self.dictionaryWords()
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
            if translation.allSatisfy(\.isNumber) || isMojibake(translation)
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

    /// Korean bytes read as Latin-1 ("ÀÇ»ó Á×À½") show up as Latin-1 symbols and C1 controls,
    /// which no real translation contains.
    private static func isMojibake(_ translation: String) -> Bool {
        translation.unicodeScalars.contains { scalar in
            (0x80...0xBF).contains(scalar.value) || scalar.value == 0xD7 || scalar.value == 0xF7
        }
    }

    /// "Fine Dry Sand" -> "Dry Sand", "Red_Potion" -> "Red Potion": the same English words rearranged.
    private static func isRespelling(_ term: String, _ translation: String) -> Bool {
        let termWords = words(of: term)
        let translationWords = words(of: translation)
        guard !termWords.isEmpty, !translationWords.isEmpty else {
            return false
        }
        let shared = termWords.intersection(translationWords).count
        return shared * 2 >= min(termWords.count, translationWords.count)
    }

    private static func words(of text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    private static func dictionaryWords() -> Set<String> {
        guard let contents = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else {
            return []
        }
        return Set(contents.split(separator: "\n").map { $0.lowercased() })
    }

    // MARK: - Loading

    private static func load<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    /// Every `<language>.lproj` in the converter output except English.
    private static func languages(in dataURL: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dataURL.path)
            .filter { $0.hasSuffix(".lproj") && $0 != "en.lproj" }
            .map { String($0.dropLast(".lproj".count)) }
            .sorted()
    }

    /// English monster names from swift-rathena's `db/re/mob_db.yml`; the converter has none.
    /// A line-based scan is enough for that layout. Empty if the checkout is absent.
    private static func rathenaMonsterNames() throws -> [(Int, String)] {
        let url = URL(filePath: "swift-rathena/db/re/mob_db.yml")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        var names: [(Int, String)] = []
        var currentID: Int?
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- Id: "), let id = Int(trimmed.dropFirst("- Id: ".count)) {
                currentID = id
            } else if trimmed.hasPrefix("Name: "), let id = currentID {
                names.append((id, String(trimmed.dropFirst("Name: ".count)).trimmingCharacters(in: .whitespaces)))
                currentID = nil
            }
        }
        return names
    }
}
