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

/// Where a translation stands, named after the string states of an Xcode string catalog.
enum TranslationState: String, Codable {
    /// No translation yet. `error` and `output` say why, if the model already tried.
    case new
    /// Produced by the model and passed validation, but not looked at by a person.
    case needsReview = "needs_review"
    /// Confirmed or fixed by a person. Wins over a model translation of the same text and is
    /// never sent to the model again.
    case translated
}

struct TranslatedScript: Codable {
    var kind: ExtractedScript.Kind
    var npc: String?
    var line: Int
    var text: String
    var placeholders: [String]?
    var state: TranslationState
    /// The translated text; nil when the model produced nothing acceptable.
    var translation: String?
    /// Why the translation was rejected, with the model's last output.
    var error: String?
    var output: String?

    func isSource(_ script: ExtractedScript) -> Bool {
        kind == script.kind && npc == script.npc && line == script.line
            && text == script.text && placeholders == script.placeholders
    }

    init(_ script: ExtractedScript, translation: String?, state: TranslationState, failure: TranslationFailure?) {
        kind = script.kind
        npc = script.npc
        line = script.line
        text = script.text
        placeholders = script.placeholders
        self.state = translation == nil ? .new : state
        self.translation = translation
        error = translation == nil ? failure?.reason : nil
        output = translation == nil ? failure?.output : nil
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
    /// Texts whose translation in `texts` is `translated` rather than `needsReview`.
    var reviewed: Set<String> = []
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
                    if script.state == .translated {
                        texts[script.text] = translation
                        reviewed.insert(script.text)
                    } else if !reviewed.contains(script.text) {
                        texts[script.text] = translation
                    }
                } else if let error = script.error {
                    failures[script.text] = TranslationFailure(reason: error, output: script.output ?? "")
                }
            }
        }
    }

    /// The state of the translation of `text` in `texts`.
    func state(of text: String) -> TranslationState {
        reviewed.contains(text) ? .translated : .needsReview
    }
}
