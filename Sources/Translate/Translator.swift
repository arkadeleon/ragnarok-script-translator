//
//  Translator.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/23.
//

import Foundation

/// One text to translate, as sent to the model.
struct TranslationItem: Encodable {
    var id: Int
    var text: String
}

/// A model backend that translates a batch of texts, asking for a JSON array back so answers
/// cannot be misattributed.
protocol Translator: Sendable {
    /// Returns translations keyed by item id; ids the model skipped are absent.
    func translate(_ items: [TranslationItem], system: String) async throws -> [Int: String]
}

struct TranslatorError: Error, CustomStringConvertible {
    var description: String
}

/// The response shape: `{"translations": [{"id": 1, "text": "..."}]}`.
struct TranslationSchema: Encodable {
    var type = "object"
    var properties = ["translations": Translations()]
    var required = ["translations"]
    var additionalProperties = false

    struct Translations: Encodable {
        var type = "array"
        var items = Item()
    }
    struct Item: Encodable {
        var type = "object"
        var properties = ["id": Field(type: "integer"), "text": Field(type: "string")]
        var required = ["id", "text"]
        var additionalProperties = false
    }
    struct Field: Encodable {
        var type: String
    }
}

private struct TranslationResponse: Decodable {
    struct Translation: Decodable {
        var id: Int
        var text: String
    }
    var translations: [Translation]
}

extension Translator {
    /// The user message: the items as JSON.
    static func payload(for items: [TranslationItem]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: try encoder.encode(["items": items]), as: UTF8.self)
    }

    /// Parses the model's answer, which must follow `TranslationSchema`.
    static func parse(_ content: String) throws -> [Int: String] {
        guard let parsed = try? JSONDecoder().decode(TranslationResponse.self, from: Data(content.utf8)) else {
            throw TranslatorError(description: "Model did not return the expected JSON: \(content.prefix(200))")
        }
        var result: [Int: String] = [:]
        for translation in parsed.translations {
            result[translation.id] = translation.text
        }
        return result
    }
}
