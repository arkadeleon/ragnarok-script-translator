//
//  Translate.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/21.
//

import ArgumentParser
import Foundation

/// Translates extracted pages with an instruction model, one source file at a time: batches in
/// dialogue order so the model sees the conversation flow, terminology in the prompt, mechanical
/// validation, and a translated copy of each file written as soon as it is done. Speaker names are
/// translated once each. At the end, everything is aggregated into `ScriptText.json` and
/// `SpeakerName.json`, keyed by the page exactly as the client receives it.
///
/// Re-running after `extract` picks up upstream changes: a file is redone when its extracted
/// scripts no longer match the translated copy, and only the texts not yet in the cache go to the
/// model. Translated files whose source disappeared are removed.
struct Translate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Translates extracted scripts into the target language with an Ollama model."
    )

    @Option(name: .shortAndLong, help: "Target language code, e.g. zh-Hans.")
    var language: String

    @Option(name: .shortAndLong, help: "Directory containing the extracted JSON files.")
    var input: String = "Extracted"

    @Option(name: .shortAndLong, help: "Directory to write <language>.lproj/ into.")
    var output: String = "Translated"

    @Option(help: "Directory holding <language>.lproj/Glossary.json terminology.")
    var glossary: String = "Glossary"

    @Option(help: "Ollama model name.")
    var model: String = "gemma4:12b"

    @Option(help: "Ollama server URL.")
    var endpoint: String = "http://localhost:11434"

    @Option(help: "Texts per request.")
    var batchSize: Int = 20

    @Option(help: "Translate at most this many files, then stop.")
    var limit: Int?

    @Flag(help: "Retry the entries that failed previously.")
    var retryFailed = false

    private static let maxAttempts = 3
    private static let speakerBatchSize = 40

    func run() async throws {
        guard let endpointURL = URL(string: endpoint) else {
            throw ValidationError("Invalid endpoint: \(endpoint)")
        }

        let inputURL = URL(filePath: input)
        let outputURL = URL(filePath: output).appending(path: "\(language).lproj")
        let translator = OllamaTranslator(endpoint: endpointURL, model: model)
        let glossary = try Glossary(directory: URL(filePath: self.glossary), language: language)
        var cache = try TranslationCache(directory: outputURL)

        // Relative paths like `cities/prontera.json`, shared by Extracted/ and the output.
        let files = try Self.extractedFiles(in: inputURL)
        let decoder = JSONDecoder()
        var pending: [String] = []
        for file in files {
            let extracted = try decoder.decode(ExtractedFile.self, from: Data(contentsOf: inputURL.appending(path: file)))
            if let data = try? Data(contentsOf: outputURL.appending(path: file)),
               let translated = try? decoder.decode(TranslatedFile.self, from: data),
               translated.matches(extracted), !(retryFailed && translated.hasFailures) {
                continue
            }
            pending.append(file)
        }
        let removed = try Self.removeOrphans(in: outputURL, keeping: Set(files))
        let translatedCount = files.count - pending.count
        if let limit {
            pending = Array(pending.prefix(limit))
        }
        print("\(files.count) files, \(translatedCount) up to date, \(pending.count) to translate, \(removed) removed; \(cache.texts.count) texts and \(cache.speakers.count) speakers cached, \(glossary.count) glossary terms")

        let start = Date()
        for (index, file) in pending.enumerated() {
            let extracted = try JSONDecoder().decode(ExtractedFile.self, from: Data(contentsOf: inputURL.appending(path: file)))
            try await translate(extracted, cache: &cache, glossary: glossary, translator: translator)

            let translated = Self.translatedFile(for: extracted, cache: cache)
            try Self.write(translated, to: outputURL.appending(path: file))

            let failures = translated.scripts.filter { $0.error != nil }.count
            printProgress(done: index + 1, total: pending.count, start: start, file: extracted.file, scripts: extracted.scripts.count, failures: failures)
        }

        try Self.aggregate(from: outputURL, cache: cache)
    }

    // MARK: - Translating one file

    private struct Pending {
        var text: String
        var speaker: String?
    }

    /// Translates whatever in `extracted` the cache does not have yet: speakers first, then bodies.
    private func translate(_ extracted: ExtractedFile, cache: inout TranslationCache, glossary: Glossary, translator: OllamaTranslator) async throws {
        var speakers: [Pending] = []
        var seenSpeakers: Set<String> = []
        var texts: [Pending] = []
        var seenTexts: Set<String> = []

        for script in extracted.scripts {
            if let speaker = script.speaker, Self.needsTranslation(speaker), cache.speakers[speaker] == nil,
               seenSpeakers.insert(speaker).inserted {
                speakers.append(Pending(text: speaker, speaker: nil))
            }
            let text = script.text
            guard !text.isEmpty, cache.texts[text] == nil, seenTexts.insert(text).inserted else { continue }
            if cache.failures[text] != nil && !retryFailed { continue }
            texts.append(Pending(text: text, speaker: script.speaker))
        }

        if !speakers.isEmpty {
            let results = try await translateBatched(
                speakers, batchSize: Self.speakerBatchSize, glossary: glossary, translator: translator,
                system: { TranslationPrompt.speakers(language: language, glossary: $0) },
                validate: TranslationValidator.validateSpeaker
            )
            for (speaker, outcome) in results {
                // A name the model cannot handle stays English rather than blocking the page.
                cache.speakers[speaker] = (try? outcome.get()) ?? speaker
            }
        }

        if !texts.isEmpty {
            let results = try await translateBatched(
                texts, batchSize: batchSize, glossary: glossary, translator: translator,
                system: { TranslationPrompt.system(language: language, glossary: $0) },
                validate: TranslationValidator.validate
            )
            for (text, outcome) in results {
                switch outcome {
                case .success(let translation):
                    cache.texts[text] = translation
                    cache.failures.removeValue(forKey: text)
                case .failure(let failure):
                    cache.failures[text] = failure
                }
            }
        }
    }

    private enum Outcome {
        case success(String)
        case failure(TranslationFailure)

        func get() throws -> String {
            switch self {
            case .success(let value): return value
            case .failure(let failure): throw OutcomeError(failure: failure)
            }
        }
    }

    private struct OutcomeError: Error {
        var failure: TranslationFailure
    }

    /// Sends `pending` in batches, retrying rejected items in fresh batches up to `maxAttempts`.
    private func translateBatched(
        _ pending: [Pending],
        batchSize: Int,
        glossary: Glossary,
        translator: OllamaTranslator,
        system: ([(term: String, translation: String)]) -> String,
        validate: (String, String) -> String?
    ) async throws -> [(String, Outcome)] {
        var results: [(String, Outcome)] = []

        for batchStart in stride(from: 0, to: pending.count, by: batchSize) {
            var remaining = Array(pending[batchStart..<min(batchStart + batchSize, pending.count)])
            var lastFailures: [String: TranslationFailure] = [:]

            for _ in 0..<Self.maxAttempts where !remaining.isEmpty {
                let items = remaining.enumerated().map { TranslationItem(id: $0.offset + 1, speaker: $0.element.speaker, text: $0.element.text) }
                let prompt = system(glossary.entries(in: remaining.map(\.text)))
                let outputs = try await translator.translate(items, system: prompt)

                var retry: [Pending] = []
                for (index, item) in remaining.enumerated() {
                    guard let raw = outputs[index + 1] else {
                        lastFailures[item.text] = TranslationFailure(reason: "missing from response", output: "")
                        retry.append(item)
                        continue
                    }
                    let output = TranslationValidator.tidy(raw, source: item.text)
                    if let reason = validate(item.text, output) {
                        lastFailures[item.text] = TranslationFailure(reason: reason, output: output)
                        retry.append(item)
                        continue
                    }
                    results.append((item.text, .success(output)))
                }
                remaining = retry
            }

            for item in remaining {
                results.append((item.text, .failure(lastFailures[item.text] ?? TranslationFailure(reason: "no attempts", output: ""))))
            }
        }
        return results
    }

    private static func needsTranslation(_ speaker: String) -> Bool {
        speaker.contains(where: \.isLetter)
    }

    // MARK: - Output

    private static func translatedFile(for extracted: ExtractedFile, cache: TranslationCache) -> TranslatedFile {
        var speakers: [String: String] = [:]
        let scripts = extracted.scripts.map { script in
            if let speaker = script.speaker, let translation = cache.speakers[speaker] {
                speakers[speaker] = translation
            }
            if script.text.isEmpty {
                return TranslatedScript(script, translation: "", failure: nil)
            }
            return TranslatedScript(script, translation: cache.texts[script.text], failure: cache.failures[script.text])
        }
        return TranslatedFile(file: extracted.file, speakers: speakers, scripts: scripts)
    }

    /// `ScriptText.json` (page as the client receives it, speaker line included, to translated page)
    /// and `SpeakerName.json`, built from every translated file.
    private static func aggregate(from outputURL: URL, cache: TranslationCache) throws {
        guard let enumerator = FileManager.default.enumerator(at: outputURL, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return
        }
        let decoder = JSONDecoder()
        var pages: [String: String] = [:]
        var speakers: [String: String] = [:]
        for case let url as URL in enumerator where url.pathExtension == "json" {
            guard let file = try? decoder.decode(TranslatedFile.self, from: Data(contentsOf: url)) else { continue }
            speakers.merge(file.speakers) { current, _ in current }
            for script in file.scripts {
                guard let translation = script.translation else { continue }
                let key = page(speaker: script.speaker, text: script.text)
                let translatedSpeaker = script.speaker.map { file.speakers[$0] ?? $0 }
                pages[key] = page(speaker: translatedSpeaker, text: translation)
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(pages).write(to: outputURL.appending(path: "ScriptText.json"), options: .atomic)
        try encoder.encode(speakers).write(to: outputURL.appending(path: "SpeakerName.json"), options: .atomic)
        print("Aggregated \(pages.count) pages and \(speakers.count) speakers into \(outputURL.path)")
    }

    /// The page as the client receives it: the speaker line, then the body.
    private static func page(speaker: String?, text: String) -> String {
        guard let speaker else {
            return text
        }
        return text.isEmpty ? "[\(speaker)]" : "[\(speaker)]\n\(text)"
    }

    private static func write(_ file: TranslatedFile, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(file).write(to: url, options: .atomic)
    }

    // MARK: - Files

    /// Deletes translated files whose extracted source no longer exists. The aggregate tables at
    /// the top level are not per-file outputs and are left alone.
    private static func removeOrphans(in outputURL: URL, keeping files: Set<String>) throws -> Int {
        guard let enumerator = FileManager.default.enumerator(atPath: outputURL.path) else {
            return 0
        }
        var removed = 0
        for case let path as String in enumerator where path.hasSuffix(".json") && path.contains("/") && !files.contains(path) {
            try FileManager.default.removeItem(at: outputURL.appending(path: path))
            removed += 1
        }
        return removed
    }

    /// Paths of the extracted JSON files relative to `directory`, sorted.
    private static func extractedFiles(in directory: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else {
            throw ValidationError("Cannot enumerate \(directory.path)")
        }
        var files: [String] = []
        for case let path as String in enumerator where path.hasSuffix(".json") {
            files.append(path)
        }
        return files.sorted()
    }

    // MARK: - Progress

    private func printProgress(done: Int, total: Int, start: Date, file: String, scripts: Int, failures: Int) {
        let elapsed = Date().timeIntervalSince(start)
        let remaining = elapsed / Double(done) * Double(total - done)
        let note = failures > 0 ? ", \(failures) failed" : ""
        print(String(format: "%d/%d  %@ (%d scripts%@)  ETA %@", done, total, file, scripts, note, Self.format(seconds: remaining)))
    }

    private static func format(seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return total >= 3600 ? "\(total / 3600)h\(total % 3600 / 60)m" : "\(total / 60)m\(total % 60)s"
    }
}
