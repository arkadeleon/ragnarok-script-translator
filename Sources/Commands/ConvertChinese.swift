//
//  ConvertChinese.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/10/9.
//

import ArgumentParser
import Foundation

/// Converts the Simplified Chinese translations in `Translated/zh-Hans.lproj/` into Traditional
/// Chinese in `Translated/zh-Hant.lproj/` with OpenCC, keeping each file's layout and states.
struct ConvertChinese: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Converts Simplified Chinese translations into Traditional Chinese with OpenCC."
    )

    @Option(name: .shortAndLong, help: "Directory containing <language>.lproj/ translated files.")
    var directory: String = "Translated"

    @Option(help: "OpenCC configuration to convert with.")
    var config: String = "s2twp.json"

    func run() throws {
        let directoryURL = URL(filePath: directory)
        let sourceURL = directoryURL.appending(path: "zh-Hans.lproj")
        let targetURL = directoryURL.appending(path: "zh-Hant.lproj")

        guard let enumerator = FileManager.default.enumerator(at: sourceURL, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw OpenCCError(description: "\(sourceURL.path) does not exist")
        }

        let decoder = JSONDecoder()
        var files: [(relativePath: String, file: TranslatedFile)] = []
        for case let url as URL in enumerator where url.pathExtension == "json" {
            guard let file = try? decoder.decode(TranslatedFile.self, from: Data(contentsOf: url)) else {
                continue
            }
            let relativePath = url.path.replacingOccurrences(of: sourceURL.path + "/", with: "")
            files.append((relativePath, file))
        }

        // One OpenCC run for every translation, since starting it per text is slow.
        let translations = files.flatMap { $0.file.scripts.compactMap(\.translation) }
        var converted = try OpenCC.convert(translations, config: config).makeIterator()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        for (relativePath, var file) in files {
            for index in file.scripts.indices where file.scripts[index].translation != nil {
                file.scripts[index].translation = converted.next()
            }
            let url = targetURL.appending(path: relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(file).write(to: url, options: .atomic)
        }

        print("Converted \(translations.count) translations in \(files.count) files into \(targetURL.path)")
    }
}
