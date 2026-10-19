import Foundation

/// A vision model behind an OpenAI-compatible chat completions API: OpenAI, OpenRouter, or a local server such as
/// LM Studio or Ollama. Images go inline as JPEG data URLs. Sending a reference to a cloud API sends the person's
/// images there, so the app only uses this when the person sets it up.
public struct OpenAICompatibleVisionModel: VisionLanguageModel {
    /// The API's base, up to `/v1`: `https://api.openai.com/v1`, `http://localhost:1234/v1`.
    public let base: URL
    public let model: String
    public let key: String?
    public var session: URLSession = .shared
    public var name: String { model }

    public init(base: URL, model: String, key: String?, session: URLSession = .shared) {
        (self.base, self.model, self.key, self.session) = (base, model, key, session)
    }

    public func availability() async -> VisionModelAvailability {
        model.isEmpty ? .unavailable("No model name is set.") : .available
    }

    public func respond(to prompt: String, images: [URL], maxTokens: Int) async throws -> String {
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        for url in images {
            let data = try Data(contentsOf: url)
            let type = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
            content.append([
                "type": "image_url", "image_url": ["url": "data:\(type);base64,\(data.base64EncodedString())"],
            ])
        }
        let body: [String: Any] = [
            "model": model, "temperature": 0, "max_tokens": maxTokens,
            "messages": [["role": "user", "content": content]],
        ]
        var request = URLRequest(url: base.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw VisionModelError.failed("The API answered \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any], let text = message["content"] as? String
        else { throw VisionModelError.failed("The API's answer has no message.") }
        return text
    }

    public func unload() async {}
}
