import Foundation

enum LoreServiceError: LocalizedError {
  case missingAPIKey
  case invalidResponse
  case upstream(status: Int, body: String)
  case decoding(Error)
  case transport(Error)

  var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      return "Set your OpenRouter API key in Settings before capturing."
    case .invalidResponse:
      return "Got an empty response from OpenRouter."
    case .upstream(let status, let body):
      return "OpenRouter returned HTTP \(status): \(body.prefix(200))"
    case .decoding(let error):
      return "Couldn't parse the response: \(error.localizedDescription)"
    case .transport(let error):
      return "Network error: \(error.localizedDescription)"
    }
  }
}

struct LoreService {
  let urlSession: URLSession
  let apiKeyProvider: () -> String?
  let modelProvider: () -> String

  init(
    urlSession: URLSession = .shared,
    apiKeyProvider: @escaping () -> String? = { LoreSecrets.apiKey },
    modelProvider: @escaping () -> String = { LoreSecrets.model }
  ) {
    self.urlSession = urlSession
    self.apiKeyProvider = apiKeyProvider
    self.modelProvider = modelProvider
  }

  func lore(forJPEG jpegData: Data) async throws -> String {
    guard let apiKey = apiKeyProvider() else { throw LoreServiceError.missingAPIKey }

    let dataURL = "data:image/jpeg;base64,\(jpegData.base64EncodedString())"

    let payload = ChatRequest(
      model: modelProvider(),
      messages: [
        .init(role: "system", content: .text(LoreConfig.systemPrompt)),
        .init(role: "user", content: .multipart([
          .text(LoreConfig.userPrompt),
          .imageURL(dataURL),
        ])),
      ],
      max_tokens: LoreConfig.maxOutputTokens
    )

    var request = URLRequest(url: LoreConfig.openRouterBaseURL)
    request.httpMethod = "POST"
    request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.addValue(LoreConfig.httpReferer, forHTTPHeaderField: "HTTP-Referer")
    request.addValue(LoreConfig.appTitle, forHTTPHeaderField: "X-Title")
    request.httpBody = try JSONEncoder().encode(payload)

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await urlSession.data(for: request)
    } catch {
      throw LoreServiceError.transport(error)
    }

    guard let http = response as? HTTPURLResponse else {
      throw LoreServiceError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw LoreServiceError.upstream(status: http.statusCode, body: body)
    }

    let decoded: ChatResponse
    do {
      decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
    } catch {
      throw LoreServiceError.decoding(error)
    }

    let text = decoded.choices.first?.message.textContent?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard !text.isEmpty else { throw LoreServiceError.invalidResponse }
    return text
  }
}

// MARK: - Wire types (OpenAI-compatible via OpenRouter)

private struct ChatRequest: Encodable {
  let model: String
  let messages: [Message]
  let max_tokens: Int

  struct Message: Encodable {
    let role: String
    let content: Content

    enum Content: Encodable {
      case text(String)
      case multipart([Part])

      func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let string):
          try container.encode(string)
        case .multipart(let parts):
          try container.encode(parts)
        }
      }
    }

    enum Part: Encodable {
      case text(String)
      case imageURL(String)

      func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let string):
          try container.encode("text", forKey: .type)
          try container.encode(string, forKey: .text)
        case .imageURL(let url):
          try container.encode("image_url", forKey: .type)
          try container.encode(ImageURL(url: url), forKey: .image_url)
        }
      }

      private struct ImageURL: Encodable {
        let url: String
      }

      private enum CodingKeys: String, CodingKey {
        case type, text, image_url
      }
    }
  }
}

private struct ChatResponse: Decodable {
  let choices: [Choice]

  struct Choice: Decodable {
    let message: ResponseMessage
  }

  struct ResponseMessage: Decodable {
    let content: RawContent

    var textContent: String? {
      switch content {
      case .string(let s): return s
      case .parts(let parts):
        return parts.compactMap { $0.text }.joined(separator: " ")
      }
    }

    enum RawContent: Decodable {
      case string(String)
      case parts([Part])

      struct Part: Decodable {
        let type: String?
        let text: String?
      }

      init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
          self = .string(s)
        } else {
          self = .parts(try container.decode([Part].self))
        }
      }
    }
  }
}
