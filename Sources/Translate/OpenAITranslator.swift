//
//  OpenAITranslator.swift
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

/// Translates a batch of texts with a model behind an OpenAI-compatible `/chat/completions`
/// endpoint, such as Alibaba Cloud Model Studio (DashScope) serving Qwen, asking for a JSON array
/// back so answers cannot be misattributed.
struct OpenAITranslator {
    struct Error: Swift.Error, CustomStringConvertible {
        var description: String
    }

    var endpoint: URL
    var apiKey: String
    var model: String
    var maxOutputTokens = 65536

    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            var role: String
            var content: String
        }
        struct ResponseFormat: Encodable {
            struct Schema: Encodable {
                var name = "translations"
                var strict = true
                var schema = JSONSchema()
            }
            var type = "json_schema"
            var json_schema = Schema()
        }
        var model: String
        var messages: [Message]
        var temperature = 0.2
        var max_tokens: Int
        var response_format = ResponseFormat()
        /// DashScope extension; Qwen hybrid models would otherwise be free to think first.
        var enable_thinking = false
    }

    /// The response shape: `{"translations": [{"id": 1, "text": "..."}]}`.
    private struct JSONSchema: Encodable {
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

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                var content: String?
            }
            var message: Message
        }
        var choices: [Choice]
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
            max_tokens: maxOutputTokens
        )

        var urlRequest = URLRequest(url: endpoint.appending(path: "chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try encoder.encode(request)
        urlRequest.timeoutInterval = 3600

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw Error(description: "\(endpoint.host() ?? "Server") returned HTTP \(status): \(String(decoding: data, as: UTF8.self))")
        }

        let chat = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = chat.choices.first?.message.content,
              let parsed = try? JSONDecoder().decode(Translations.self, from: Data(content.utf8)) else {
            throw Error(description: "Model did not return the expected JSON: \(String(decoding: data, as: UTF8.self).prefix(200))")
        }

        var result: [Int: String] = [:]
        for translation in parsed.translations {
            result[translation.id] = translation.text
        }
        return result
    }
}
