//
//  RagnarokScriptTranslator.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/21.
//

import ArgumentParser

@main
struct RagnarokScriptTranslator: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ragnarok-script-translator",
        abstract: "Extracts translatable text from rAthena NPC scripts and translates it.",
        subcommands: [
            Extract.self,
            Import.self,
            GenerateGlossary.self,
            Translate.self,
            ConvertChinese.self,
            Export.self,
        ]
    )
}
