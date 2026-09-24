//
//  OpenAITranslator.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/23.
//

import Foundation

/// Translates with a model behind an OpenAI-compatible `/chat/completions` endpoint, such as
/// Alibaba Cloud Model Studio (DashScope) serving Qwen.
struct OpenAITranslator: Translator {
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
                var schema = TranslationSchema()
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

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                var content: String?
            }
            var message: Message
        }
        var choices: [Choice]
    }

    func translate(_ request: TranslationRequest, system: String) async throws -> [Int: String] {
        let chatRequest = ChatRequest(
            model: model,
            messages: [.init(role: "system", content: system), .init(role: "user", content: try Self.payload(for: request))],
            max_tokens: maxOutputTokens
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        var urlRequest = URLRequest(url: endpoint.appending(path: "chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try encoder.encode(chatRequest)
        urlRequest.timeoutInterval = 3600

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TranslatorError(description: "\(endpoint.host() ?? "Server") returned HTTP \(status): \(String(decoding: data, as: UTF8.self))")
        }

        let chat = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = chat.choices.first?.message.content else {
            throw TranslatorError(description: "Response has no content: \(String(decoding: data, as: UTF8.self).prefix(200))")
        }
        return try Self.parse(content)
    }
}
