//
//  Extract.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/21.
//

import ArgumentParser
import Foundation

struct Extract: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Fetches swift-rathena and extracts translatable NPC script text into JSON files."
    )

    @Option(name: .shortAndLong, help: "Directory to write JSON files into.")
    var output: String = "Extracted"

    func run() throws {
        let repositoryURL = URL(filePath: "swift-rathena")
        let outputURL = URL(filePath: output)

        try Git.sync(repository: repositoryURL, from: "https://github.com/arkadeleon/swift-rathena.git")

        try? FileManager.default.removeItem(at: outputURL)

        let npcURL = repositoryURL.appending(path: "npc")
        let files = try scriptFiles(in: npcURL)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        var totalScripts = 0
        var totalFiles = 0

        for fileURL in files {
            let relativePath = fileURL.path.replacingOccurrences(of: npcURL.path + "/", with: "")
            let data = try Data(contentsOf: fileURL)
            let source = String(decoding: data, as: UTF8.self)

            let scripts = ScriptExtractor(source: source).extract()
            guard !scripts.isEmpty else {
                continue
            }

            let file = ExtractedFile(file: "npc/" + relativePath, scripts: scripts)
            let jsonURL = outputURL
                .appending(path: relativePath)
                .deletingPathExtension()
                .appendingPathExtension("json")
            try FileManager.default.createDirectory(at: jsonURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(file).write(to: jsonURL)

            totalScripts += scripts.count
            totalFiles += 1
        }

        print("Extracted \(totalScripts) scripts from \(totalFiles) files into \(outputURL.path)")
    }

    private func scriptFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw ValidationError("Cannot enumerate \(directory.path)")
        }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "txt" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }
}
