//
//  OllamaTranslator.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/22.
//

import Foundation

/// One text to translate, as sent to the model.
struct TranslationItem: Encodable {
    var id: Int
    var speaker: String?
    var text: String
}

/// Translates a batch of texts with an instruction model served by Ollama (`/api/chat`), asking
/// for a JSON array back so answers cannot be misattributed.
struct OllamaTranslator {
    struct Error: Swift.Error, CustomStringConvertible {
        var description: String
    }

    var endpoint: URL
    var model: String
    var contextLength = 16384

    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            var role: String
            var content: String
        }
        struct Options: Encodable {
            var temperature: Double
            var num_ctx: Int
        }
        var model: String
        var messages: [Message]
        var stream = false
        var think = false
        var format: JSONSchema
        var options: Options
    }

    /// The response shape: `{"translations": [{"id": 1, "text": "..."}]}`.
    private struct JSONSchema: Encodable {
        var type = "object"
        var properties = ["translations": Translations()]
        var required = ["translations"]

        struct Translations: Encodable {
            var type = "array"
            var items = Item()
        }
        struct Item: Encodable {
            var type = "object"
            var properties = ["id": Field(type: "integer"), "text": Field(type: "string")]
            var required = ["id", "text"]
        }
        struct Field: Encodable {
            var type: String
        }
    }

    private struct ChatResponse: Decodable {
        struct Message: Decodable {
            var content: String
        }
        var message: Message
        var eval_count: Int?
        var prompt_eval_count: Int?
    }

    private struct Translations: Decodable {
        struct Translation: Decodable {
            var id: Int
            var text: String
        }
        var translations: [Translation]
    }

    /// Returns translations keyed by item id; ids the model skipped are absent.
    func translate(_ items: [TranslationItem], system: String) async throws -> [Int: String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let payload = String(decoding: try encoder.encode(["items": items]), as: UTF8.self)

        let request = ChatRequest(
            model: model,
            messages: [.init(role: "system", content: system), .init(role: "user", content: payload)],
            format: JSONSchema(),
            options: .init(temperature: 0.2, num_ctx: contextLength)
        )

        var urlRequest = URLRequest(url: endpoint.appending(path: "api/chat"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(request)
        urlRequest.timeoutInterval = 3600

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw Error(description: "Ollama returned HTTP \(status): \(String(decoding: data, as: UTF8.self))")
        }

        let chat = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = chat.message.content.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(Translations.self, from: content) else {
            throw Error(description: "Model did not return the expected JSON: \(chat.message.content.prefix(200))")
        }

        var result: [Int: String] = [:]
        for translation in parsed.translations {
            result[translation.id] = translation.text
        }
        return result
    }
}
