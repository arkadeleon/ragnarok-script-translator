//
//  TranslatedFile.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/22.
//

import Foundation

/// One extracted file with its translations, written to `Translated/<language>.lproj/<same path>.json`
/// as soon as the file is done. Mirrors `Extracted/` so progress is visible per file and each
/// translation sits next to its source for review.
struct TranslatedFile: Codable {
    var file: String
    var scripts: [TranslatedScript]

    var hasFailures: Bool {
        scripts.contains { $0.error != nil }
    }

    /// True when this was produced from exactly these extracted scripts, so nothing needs redoing.
    func matches(_ extracted: ExtractedFile) -> Bool {
        file == extracted.file && scripts.count == extracted.scripts.count
            && zip(scripts, extracted.scripts).allSatisfy { $0.isSource($1) }
    }
}

struct TranslatedScript: Codable {
    var kind: ExtractedScript.Kind
    var npc: String?
    var line: Int
    var text: String
    var placeholders: [String]?
    /// The translated text; nil when the model produced nothing acceptable.
    var translation: String?
    /// Why the translation was rejected, with the model's last output.
    var error: String?
    var output: String?

    func isSource(_ script: ExtractedScript) -> Bool {
        kind == script.kind && npc == script.npc && line == script.line
            && text == script.text && placeholders == script.placeholders
    }

    init(_ script: ExtractedScript, translation: String?, failure: TranslationFailure?) {
        kind = script.kind
        npc = script.npc
        line = script.line
        text = script.text
        placeholders = script.placeholders
        self.translation = translation
        error = failure?.reason
        output = failure?.output
    }
}

struct TranslationFailure {
    var reason: String
    var output: String
}

/// Everything already translated for a language, gathered from the per-file outputs so texts
/// shared between files are translated once and interrupted runs resume where they stopped.
struct TranslationCache {
    var texts: [String: String] = [:]
    var failures: [String: TranslationFailure] = [:]

    init() {}

    init(directory: URL) throws {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return
        }
        let decoder = JSONDecoder()
        for case let url as URL in enumerator where url.pathExtension == "json" {
            guard let file = try? decoder.decode(TranslatedFile.self, from: Data(contentsOf: url)) else {
                continue // the aggregate table, or something that is not ours
            }
            for script in file.scripts {
                if let translation = script.translation {
                    texts[script.text] = translation
                } else if let error = script.error {
                    failures[script.text] = TranslationFailure(reason: error, output: script.output ?? "")
                }
            }
        }
    }
}
