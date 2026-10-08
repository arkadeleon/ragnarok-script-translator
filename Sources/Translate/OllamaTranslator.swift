//
//  OllamaTranslator.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/22.
//

import Foundation

struct OllamaTranslationError: Error, CustomStringConvertible {
    var description: String
}

/// Translates with an instruction model served by Ollama (`/api/chat`), asking for a JSON array
/// back so answers cannot be misattributed.
struct OllamaTranslator: Sendable {
    var endpoint: URL
    var model: String
    var contextLength = 16384
    var maxOutputTokens = 8192

    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            var role: String
            var content: String
        }
        struct Options: Encodable {
            var temperature: Double
            var num_ctx: Int
            var num_predict: Int
        }
        var model: String
        var messages: [Message]
        var stream = false
        var think = false
        var format: TranslationSchema
        var options: Options
    }

    private struct ChatResponse: Decodable {
        struct Message: Decodable {
            var content: String
        }
        var message: Message
    }

    /// The response shape: `{"translations": [{"id": 1, "text": "..."}]}`.
    private struct TranslationSchema: Encodable {
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

    /// Returns translations keyed by item id; ids the model skipped are absent.
    func translate(_ request: TranslationRequest, system: String) async throws -> [Int: String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let payload = String(decoding: try encoder.encode(request), as: UTF8.self)
        let chatRequest = ChatRequest(
            model: model,
            messages: [.init(role: "system", content: system), .init(role: "user", content: payload)],
            format: TranslationSchema(),
            options: .init(temperature: 0.2, num_ctx: contextLength, num_predict: maxOutputTokens)
        )

        var urlRequest = URLRequest(url: endpoint.appending(path: "api/chat"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(chatRequest)
        urlRequest.timeoutInterval = 3600

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw OllamaTranslationError(description: "Ollama returned HTTP \(status): \(String(decoding: data, as: UTF8.self))")
        }

        let content = try JSONDecoder().decode(ChatResponse.self, from: data).message.content
        guard let parsed = try? JSONDecoder().decode(TranslationResponse.self, from: Data(content.utf8)) else {
            throw OllamaTranslationError(description: "Model did not return the expected JSON: \(content.prefix(200))")
        }
        return Dictionary(parsed.translations.map { ($0.id, $0.text) }) { _, last in last }
    }
}
