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
/// validation, and a translated copy of each file written as soon as it is done.
///
/// Re-running after `extract` picks up upstream changes: a file is redone when its extracted
/// scripts no longer match the translated copy, and only the texts not yet in the cache go to the
/// model. Translated files whose source disappeared are removed.
struct Translate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Translates extracted scripts into the target language with an instruction model."
    )

    @Option(name: .shortAndLong, help: "Target language code, e.g. zh-Hans.")
    var language: String

    @Option(name: .shortAndLong, help: "Directory containing the extracted JSON files.")
    var input: String = "Extracted"

    @Option(name: .shortAndLong, help: "Directory to write <language>.lproj/ into.")
    var output: String = "Translated"

    @Option(help: "Directory holding <language>.lproj/Glossary.json terminology.")
    var glossary: String = "Glossary"

    @Option(help: "Model name.")
    var model: String = "qwen3.7-plus"

    @Option(help: "OpenAI-compatible API base URL; the key is read from DASHSCOPE_API_KEY.")
    var endpoint: String = "https://dashscope.aliyuncs.com/compatible-mode/v1"

    @Option(help: "Maximum texts per request (default: no limit).")
    var batchSize: Int?

    @Option(help: "Maximum source characters per request.")
    var batchCharacters: Int = 40000

    @Option(help: "Files translated at the same time.")
    var concurrency: Int = 10

    @Option(help: "Translate at most this many files, then stop.")
    var limit: Int?

    @Flag(help: "Retry the entries that failed previously.")
    var retryFailed = false

    private static let maxAttempts = 3

    func run() async throws {
        let translator = try makeTranslator()
        let inputURL = URL(filePath: input)
        let outputURL = URL(filePath: output).appending(path: "\(language).lproj")
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
        print("\(files.count) files, \(translatedCount) up to date, \(pending.count) to translate, \(removed) removed; \(cache.texts.count) texts cached, \(glossary.count) glossary terms")

        // Files run concurrently, each against the cache as it was when the file started; the
        // cache is only updated here, as files finish. A text shared by two files in flight at the
        // same time is translated twice, which costs little.
        let start = Date()
        var done = 0
        await withTaskGroup(of: (String, Result<(ExtractedFile, [(String, Outcome)]), any Error>).self) { group in
            var queue = pending.makeIterator()
            func startNext(cache: TranslationCache) {
                guard let file = queue.next() else {
                    return
                }
                group.addTask {
                    do {
                        let extracted = try JSONDecoder().decode(ExtractedFile.self, from: Data(contentsOf: inputURL.appending(path: file)))
                        let results = await translate(extracted, cache: cache, glossary: glossary, translator: translator)
                        return (file, .success((extracted, results)))
                    } catch {
                        return (file, .failure(error))
                    }
                }
            }
            for _ in 0..<max(concurrency, 1) {
                startNext(cache: cache)
            }

            for await (file, result) in group {
                done += 1
                do {
                    let (extracted, results) = try result.get()
                    for (text, outcome) in results {
                        switch outcome {
                        case .success(let translation):
                            cache.texts[text] = translation
                            cache.failures.removeValue(forKey: text)
                        case .failure(let failure):
                            cache.failures[text] = failure
                        }
                    }

                    let translated = Self.translatedFile(for: extracted, cache: cache)
                    try Self.write(translated, to: outputURL.appending(path: file))

                    let failures = translated.scripts.filter { $0.error != nil }.count
                    printProgress(done: done, total: pending.count, start: start, file: extracted.file, scripts: extracted.scripts.count, failures: failures)
                } catch {
                    // One bad file must not end a run that takes days; it is retried next time.
                    print("\(file): \(error)")
                }
                startNext(cache: cache)
            }
        }
    }

    private func makeTranslator() throws -> OpenAITranslator {
        guard let url = URL(string: endpoint) else {
            throw ValidationError("Invalid endpoint: \(endpoint)")
        }
        guard let apiKey = ProcessInfo.processInfo.environment["DASHSCOPE_API_KEY"], !apiKey.isEmpty else {
            throw ValidationError("Set DASHSCOPE_API_KEY to your Alibaba Cloud Model Studio API key.")
        }
        return OpenAITranslator(endpoint: url, apiKey: apiKey, model: model)
    }

    // MARK: - Translating one file

    /// Translates whatever in `extracted` the cache does not have yet.
    private func translate(_ extracted: ExtractedFile, cache: TranslationCache, glossary: Glossary, translator: OpenAITranslator) async -> [(String, Outcome)] {
        var texts: [String] = []
        var seen: Set<String> = []

        for script in extracted.scripts {
            let text = script.text
            guard !text.isEmpty, cache.texts[text] == nil, seen.insert(text).inserted else { continue }
            if cache.failures[text] != nil && !retryFailed { continue }
            texts.append(text)
        }
        guard !texts.isEmpty else {
            return []
        }
        return await translateBatched(texts, glossary: glossary, translator: translator)
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

    /// Sends `texts` in batches, retrying rejected ones in fresh batches up to `maxAttempts`.
    private func translateBatched(
        _ texts: [String],
        glossary: Glossary,
        translator: OpenAITranslator
    ) async -> [(String, Outcome)] {
        var results: [(String, Outcome)] = []

        for batch in batches(of: texts) {
            var remaining = batch
            var lastFailures: [String: TranslationFailure] = [:]

            for _ in 0..<Self.maxAttempts where !remaining.isEmpty {
                let (outputs, errors) = await send(remaining, glossary: glossary, translator: translator)

                var retry: [String] = []
                for text in remaining {
                    guard let raw = outputs[text] else {
                        lastFailures[text] = errors[text] ?? TranslationFailure(reason: "missing from response", output: "")
                        retry.append(text)
                        continue
                    }
                    let output = TranslationValidator.tidy(raw, source: text)
                    if let reason = TranslationValidator.validate(source: text, translation: output) {
                        lastFailures[text] = TranslationFailure(reason: reason, output: output)
                        retry.append(text)
                        continue
                    }
                    results.append((text, .success(output)))
                }
                remaining = retry
            }

            for text in remaining {
                results.append((text, .failure(lastFailures[text] ?? TranslationFailure(reason: "no attempts", output: ""))))
            }
        }
        return results
    }

    /// Splits `texts` into requests in dialogue order. A cloud model takes most files whole, which
    /// gives it the whole conversation for consistent wording; the character limit keeps the
    /// response of the few very large files well inside the model's output limit.
    private func batches(of texts: [String]) -> [[String]] {
        var batches: [[String]] = []
        var batch: [String] = []
        var characters = 0
        for text in texts {
            if !batch.isEmpty, batch.count >= batchSize ?? .max || characters + text.count > batchCharacters {
                batches.append(batch)
                batch = []
                characters = 0
            }
            batch.append(text)
            characters += text.count
        }
        if !batch.isEmpty {
            batches.append(batch)
        }
        return batches
    }

    /// One request for `texts`, keyed by source text. A response the model cut short cannot be
    /// parsed, so the batch is halved and each half asked again; a single text that still fails is
    /// reported as an error rather than losing the rest of the batch.
    private func send(
        _ texts: [String],
        glossary: Glossary,
        translator: OpenAITranslator
    ) async -> (outputs: [String: String], errors: [String: TranslationFailure]) {
        let items = texts.enumerated().map { TranslationItem(id: $0.offset + 1, text: $0.element) }
        let prompt = TranslationPrompt.system(language: language, glossary: glossary.entries(in: texts))

        do {
            let outputs = try await translator.translate(items, system: prompt)
            var result: [String: String] = [:]
            for (index, text) in texts.enumerated() {
                if let output = outputs[index + 1] {
                    result[text] = output
                }
            }
            return (result, [:])
        } catch {
            guard texts.count > 1 else {
                return ([:], [texts[0]: TranslationFailure(reason: "\(error)", output: "")])
            }
            let middle = texts.count / 2
            let first = await send(Array(texts[..<middle]), glossary: glossary, translator: translator)
            let second = await send(Array(texts[middle...]), glossary: glossary, translator: translator)
            return (first.outputs.merging(second.outputs) { current, _ in current },
                    first.errors.merging(second.errors) { current, _ in current })
        }
    }

    // MARK: - Output

    private static func translatedFile(for extracted: ExtractedFile, cache: TranslationCache) -> TranslatedFile {
        let scripts = extracted.scripts.map {
            TranslatedScript($0, translation: cache.texts[$0.text], failure: cache.failures[$0.text])
        }
        return TranslatedFile(file: extracted.file, scripts: scripts)
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
