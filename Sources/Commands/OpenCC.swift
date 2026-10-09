//
//  OpenCC.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/10/9.
//

import Foundation

struct OpenCCError: Error, CustomStringConvertible {
    var description: String
}

enum OpenCC {
    /// Converts `texts` by piping them through the `opencc` command line tool as one JSON array.
    /// JSON escapes and punctuation are ASCII, so OpenCC only touches the Chinese text inside.
    static func convert(_ texts: [String], config: String) throws -> [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let input = try encoder.encode(texts)

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["opencc", "-c", config]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout

        do {
            try process.run()
        } catch {
            throw OpenCCError(description: "Failed to run opencc (install it with `brew install opencc`): \(error)")
        }

        // Write on another thread so a full stdout pipe cannot deadlock against a full stdin pipe.
        let writer = Thread {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }
        writer.start()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw OpenCCError(description: "opencc failed with status \(process.terminationStatus)")
        }

        let converted = try JSONDecoder().decode([String].self, from: output)
        guard converted.count == texts.count else {
            throw OpenCCError(description: "opencc returned \(converted.count) texts for \(texts.count)")
        }
        return converted
    }
}
