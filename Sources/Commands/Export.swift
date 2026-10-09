//
//  Export.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/10/9.
//

import ArgumentParser
import Foundation

/// Exports the translations in `Translated/` into `Exported/<language>.lproj/ScriptText.json`, a
/// flat table from the text as the server sends it, with `{0}` placeholders, to its translation.
struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Exports translated scripts into tables a client can load."
    )

    @Option(name: .shortAndLong, help: "Directory containing <language>.lproj/ translated files.")
    var input: String = "Translated"

    @Option(name: .shortAndLong, help: "Directory to write <language>.lproj/ScriptText.json into.")
    var output: String = "Exported"

    @Flag(help: "Leave out model translations nobody has reviewed.")
    var reviewedOnly = false

    func run() throws {
        let inputURL = URL(filePath: input)
        let outputURL = URL(filePath: output)

        let languages = try languages(in: inputURL)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        for language in languages {
            let directory = "\(language).lproj"

            let cache = try TranslationCache(directory: inputURL.appending(path: directory))
            let texts = reviewedOnly ? cache.texts.filter { cache.reviewed.contains($0.key) } : cache.texts

            guard !texts.isEmpty else {
                print("\(language): skipped (nothing translated)")
                continue
            }

            let url = outputURL.appending(path: "\(directory)/ScriptText.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(texts).write(to: url, options: .atomic)
            print("\(language): \(texts.count) texts into \(url.path)")
        }
    }

    /// Languages with a `<language>.lproj` directory in `directory`, sorted.
    private func languages(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".lproj") }
            .map { String($0.dropLast(".lproj".count)) }
            .sorted()
    }
}
