//
//  Git.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/21.
//

import Foundation

enum Git {
    struct Error: Swift.Error, CustomStringConvertible {
        var description: String
    }

    /// Clones `url` into `repository` if it does not exist yet, otherwise pulls the latest changes.
    static func sync(repository: URL, from url: String) throws {
        let gitDirectory = repository.appending(path: ".git")
        if FileManager.default.fileExists(atPath: gitDirectory.path) {
            print("Updating \(repository.path)")
            try run(["pull", "--ff-only"], in: repository)
        } else {
            print("Cloning \(url) into \(repository.path)")
            try FileManager.default.createDirectory(at: repository.deletingLastPathComponent(), withIntermediateDirectories: true)
            try run(["clone", "--depth", "1", url, repository.path], in: nil)
        }
    }

    private static func run(_ arguments: [String], in directory: URL?) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Error(description: "git \(arguments.joined(separator: " ")) failed with status \(process.terminationStatus)")
        }
    }
}
