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

  /// Convenience wrapper for a single-turn image capture. Builds a
  /// [system, user(image+text)] message pair and delegates to
  /// `loreChat(messages:)`.
  func lore(forJPEG jpegData: Data, systemPrompt: String) async throws -> String {
    try await loreChat(messages: [
      .system(systemPrompt),
      .user(jpegData: jpegData, text: LoreConfig.userPrompt),
    ])
  }

  /// Full-chat variant. Use this when you need to send a multi-turn
  /// conversation (e.g., follow-ups after an initial capture). The VM is
  /// responsible for maintaining the message history.
  func loreChat(messages: [LoreMessage]) async throws -> String {
    guard let apiKey = apiKeyProvider() else { throw LoreServiceError.missingAPIKey }

    var request = try makeBaseRequest(apiKey: apiKey)
    request.httpBody = try JSONEncoder().encode(
      makePayload(messages: messages, stream: false)
    )

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

  /// Streaming variant. Yields text deltas as they arrive via SSE, ending when
  /// the upstream closes or sends `data: [DONE]`. The caller is responsible
  /// for accumulating tokens into words/sentences and driving TTS.
  ///
  /// Errors are thrown through the stream's termination, so a caller that
  /// uses `for try await` will catch them naturally.
  /// Convenience wrapper for single-turn image capture streaming. Builds a
  /// [system, user(image+text)] pair and delegates to
  /// `streamLoreChat(messages:)`.
  func streamLore(
    forJPEG jpegData: Data,
    systemPrompt: String
  ) -> AsyncThrowingStream<String, Error> {
    streamLoreChat(messages: [
      .system(systemPrompt),
      .user(jpegData: jpegData, text: LoreConfig.userPrompt),
    ])
  }

  /// Full-chat streaming. Used for the initial capture AND for follow-ups —
  /// the VM builds the message history and the service just serializes it.
  func streamLoreChat(
    messages: [LoreMessage]
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          guard let apiKey = apiKeyProvider() else {
            throw LoreServiceError.missingAPIKey
          }

          var request = try makeBaseRequest(apiKey: apiKey)
          request.addValue("text/event-stream", forHTTPHeaderField: "Accept")
          request.httpBody = try JSONEncoder().encode(
            makePayload(messages: messages, stream: true)
          )

          let (bytes, response): (URLSession.AsyncBytes, URLResponse)
          do {
            (bytes, response) = try await urlSession.bytes(for: request)
          } catch {
            throw LoreServiceError.transport(error)
          }

          guard let http = response as? HTTPURLResponse else {
            throw LoreServiceError.invalidResponse
          }
          guard (200..<300).contains(http.statusCode) else {
            // Drain a small prefix for the error body so we can surface a
            // useful message without hanging on a large payload.
            var bodyBytes: [UInt8] = []
            bodyBytes.reserveCapacity(512)
            for try await byte in bytes {
              bodyBytes.append(byte)
              if bodyBytes.count >= 512 { break }
            }
            let body = String(decoding: bodyBytes, as: UTF8.self)
            throw LoreServiceError.upstream(status: http.statusCode, body: body)
          }

          var yielded = false
          let decoder = JSONDecoder()

          for try await line in bytes.lines {
            if Task.isCancelled { break }
            // SSE frames: blank separators, comment lines (`: ping`), and
            // `data: {json}` payloads. OpenRouter sends `data: [DONE]` last.
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count)
              .trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { break }

            guard let data = payload.data(using: .utf8) else { continue }
            let chunk: StreamChunk
            do {
              chunk = try decoder.decode(StreamChunk.self, from: data)
            } catch {
              // One malformed chunk shouldn't kill the whole stream; keep
              // going and let the caller notice if nothing arrives.
              continue
            }

            if let delta = chunk.choices.first?.delta.content, !delta.isEmpty {
              yielded = true
              continuation.yield(delta)
            }
          }

          if !yielded {
            throw LoreServiceError.invalidResponse
          }

          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  // MARK: - Request builders

  private func makeBaseRequest(apiKey: String) throws -> URLRequest {
    var request = URLRequest(url: LoreConfig.openRouterBaseURL)
    request.httpMethod = "POST"
    request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.addValue(LoreConfig.httpReferer, forHTTPHeaderField: "HTTP-Referer")
    request.addValue(LoreConfig.appTitle, forHTTPHeaderField: "X-Title")
    return request
  }

  private func makePayload(messages: [LoreMessage], stream: Bool) -> ChatRequest {
    ChatRequest(
      model: modelProvider(),
      messages: messages.map { $0.toWireMessage() },
      max_tokens: LoreConfig.maxOutputTokens,
      stream: stream
    )
  }
}

// MARK: - LoreMessage ↔ wire conversion

fileprivate extension LoreMessage {
  func toWireMessage() -> ChatRequest.Message {
    switch content {
    case .text(let string):
      return ChatRequest.Message(role: role.rawValue, content: .text(string))
    case .imageAndText(let jpegData, let text):
      let dataURL = "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
      return ChatRequest.Message(
        role: role.rawValue,
        content: .multipart([
          .text(text),
          .imageURL(dataURL),
        ])
      )
    }
  }
}

// MARK: - Wire types (OpenAI-compatible via OpenRouter)

private struct ChatRequest: Encodable {
  let model: String
  let messages: [Message]
  let max_tokens: Int
  // Optional so the non-streaming path serializes identically to before —
  // nil is omitted by the default encoder and older regression tests keep
  // their exact wire bytes.
  var stream: Bool?

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

// SSE chunks from OpenRouter (OpenAI-compatible). Each frame's `choices[0].delta`
// carries either a role announcement or a content token. We only care about content.
private struct StreamChunk: Decodable {
  let choices: [Choice]

  struct Choice: Decodable {
    let delta: Delta
  }

  struct Delta: Decodable {
    let content: String?
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
