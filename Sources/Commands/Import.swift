//
//  Import.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/28.
//

import ArgumentParser
import Foundation

/// Imports the official script translations of the Latin American and Global clients from
/// ragnarok-data-converter into `Imported/<language>.lproj/Scripts.json`, English text to
/// translation.
///
/// Each CSV under `data/i18n/sc` holds the lines of one script, one row per line, every column
/// base64 encoded: the English text in column 2 already uses `{0}` placeholders and joins a page
/// with `\n`, the same shape as the extracted texts. The clients order the other languages
/// differently.
struct Import: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Fetches ragnarok-data-converter and imports the official script translations of the Latin American and Global clients."
    )

    @Option(name: .shortAndLong, help: "Directory to write <language>.lproj/Scripts.json into.")
    var output: String = "Imported"

    private var englishColumn: Int {
        2
    }

    /// The script directories in ragnarok-data-converter and the column of each language in them.
    /// Global's Spanish (column 9) is left out: it adds little to the Latin American one and words
    /// much of the rest differently.
    private var sources: [(directory: String, columns: [String: Int])] {
        [
            ("Input/LatinAmerica/data/i18n/sc", ["pt-BR": 7, "es": 9]),
            ("Input/Global/data/i18n/sc", ["ko": 1, "zh-Hans": 4, "th": 6, "de": 10, "fr": 11, "id": 12, "tr": 13]),
        ]
    }

    func run() async throws {
        let repositoryURL = URL(filePath: "ragnarok-data-converter")
        try Git.sync(repository: repositoryURL, from: "https://github.com/arkadeleon/ragnarok-data-converter.git")

        // A language offered by more than one client gets the pairs of all of them.
        var pairs: [String: [(text: String, translation: String)]] = [:]
        for (directory, columns) in sources {
            let scriptsURL = repositoryURL.appending(path: directory)
            let files = try FileManager.default.contentsOfDirectory(at: scriptsURL, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "csv" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            let rows = try files.flatMap { try self.rows(in: $0) }
            print("Read \(rows.count) rows from \(files.count) files in \(directory)")

            for (language, column) in columns {
                for row in rows where column < row.count {
                    pairs[language, default: []].append((row[englishColumn], row[column]))
                }
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        for (language, pairs) in pairs.sorted(by: { $0.key < $1.key }) {
            let translations = await translations(from: pairs)
            let url = URL(filePath: output).appending(path: "\(language).lproj/Scripts.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(translations).write(to: url, options: .atomic)
            print("\(language): \(translations.count) texts into \(url.path)")
        }
    }

    /// The decoded columns of every row in `url`; empty cells decode to empty strings. Cells are
    /// base64 without line breaks; the row ids leave out the padding.
    private func rows(in url: URL) throws -> [[String]] {
        let string = try String(contentsOf: url, encoding: .utf8)
        return string.split(whereSeparator: \.isNewline).map { line in
            line.split(separator: ",", omittingEmptySubsequences: false).map { cell in
                let padded = cell + String(repeating: "=", count: (4 - cell.count % 4) % 4)
                guard let data = Data(base64Encoded: String(padded)) else {
                    return ""
                }
                return String(decoding: data, as: UTF8.self)
            }
        }
    }

    /// English text to its translation. A text that occurs in several scripts can be
    /// translated differently in each, and some rows are misaligned (`Cancel` translated as a line
    /// of dialog), so the most frequent translation that passes validation wins, the first seen on
    /// a tie. Validation parses its patterns on every call, so the texts are validated in
    /// parallel chunks.
    private func translations(from pairs: [(text: String, translation: String)]) async -> [String: String] {
        var candidates: [String: [(translation: String, count: Int)]] = [:]
        for (text, translation) in pairs {
            guard !text.isEmpty, !translation.isEmpty else {
                continue
            }
            if let index = candidates[text]?.firstIndex(where: { $0.translation == translation }) {
                candidates[text]![index].count += 1
            } else {
                candidates[text, default: []].append((translation, 1))
            }
        }

        let texts = Array(candidates)
        return await withTaskGroup(of: [String: String].self) { group in
            for start in stride(from: 0, to: texts.count, by: 1000) {
                group.addTask {
                    var translations: [String: String] = [:]
                    for (text, candidates) in texts[start..<min(start + 1000, texts.count)] {
                        var best: (translation: String, count: Int)?
                        for candidate in candidates where candidate.count > best?.count ?? 0
                            && TranslationValidator.validate(source: text, translation: candidate.translation) == nil {
                            best = candidate
                        }
                        translations[text] = best?.translation
                    }
                    return translations
                }
            }
            return await group.reduce(into: [:]) { $0.merge($1) { current, _ in current } }
        }
    }
}
