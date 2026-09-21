//
//  Translate.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/21.
//

import ArgumentParser

struct Translate: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Translates extracted scripts into the target language."
    )

    @Option(name: .shortAndLong, help: "Directory containing the extracted JSON files.")
    var input: String = "Extracted"

    @Option(name: .shortAndLong, help: "Target language code, e.g. zh-Hans.")
    var language: String

    func run() throws {
        throw ValidationError("translate is not implemented yet.")
    }
}
