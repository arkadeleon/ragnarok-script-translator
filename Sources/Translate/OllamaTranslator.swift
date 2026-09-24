//
//  OllamaTranslator.swift
//  ragnarok-script-translator
//
//  Created by Leon Li on 2026/9/22.
//

import Foundation

/// Translates with an instruction model served by Ollama (`/api/chat`).
struct OllamaTranslator: Translator {
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
        var eval_count: Int?
        var prompt_eval_count: Int?
    }

    func translate(_ request: TranslationRequest, system: String) async throws -> [Int: String] {
        let chatRequest = ChatRequest(
            model: model,
            messages: [.init(role: "system", content: system), .init(role: "user", content: try Self.payload(for: request))],
            format: TranslationSchema(),
            options: .init(temperature: 0.2, num_ctx: contextLength, num_predict: maxOutputTokens)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        var urlRequest = URLRequest(url: endpoint.appending(path: "api/chat"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(chatRequest)
        urlRequest.timeoutInterval = 3600

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TranslatorError(description: "Ollama returned HTTP \(status): \(String(decoding: data, as: UTF8.self))")
        }

        let chat = try JSONDecoder().decode(ChatResponse.self, from: data)
        return try Self.parse(chat.message.content)
    }
}
