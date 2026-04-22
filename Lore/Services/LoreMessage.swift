import Foundation

/// One turn in a conversation with the model. Shape mirrors the OpenAI chat
/// completions schema without leaking OpenRouter wire types into the
/// ViewModel. The VM builds an array of these and hands it to
/// `LoreService.streamLoreChat(messages:)`, which serializes the payload.
///
/// The image only rides along on the first user turn (`.imageAndText`).
/// Follow-ups ("Tell me more") are text-only so we don't re-upload the JPEG
/// on every round-trip — a 1 MB photo times N follow-ups gets expensive
/// fast, and the vision model keeps the image in-context automatically.
struct LoreMessage {
  enum Role: String {
    case system
    case user
    case assistant
  }

  enum Content {
    case text(String)
    case imageAndText(jpegData: Data, text: String)
  }

  let role: Role
  let content: Content

  static func system(_ text: String) -> LoreMessage {
    .init(role: .system, content: .text(text))
  }

  static func user(_ text: String) -> LoreMessage {
    .init(role: .user, content: .text(text))
  }

  static func user(jpegData: Data, text: String) -> LoreMessage {
    .init(role: .user, content: .imageAndText(jpegData: jpegData, text: text))
  }

  static func assistant(_ text: String) -> LoreMessage {
    .init(role: .assistant, content: .text(text))
  }
}
