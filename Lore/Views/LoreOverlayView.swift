import SwiftUI

struct LoreOverlayView: View {
  let state: LoreFlowState
  /// True when the parent VM is ready to accept a "Tell me more" turn.
  /// The overlay shows the follow-up button only in `.finished` state AND
  /// only when this flag is on — so it disappears mid-stream, after
  /// dismissal, and once max depth is hit.
  let canFollowUp: Bool
  let onDismiss: () -> Void
  let onRetry: () -> Void
  let onFollowUp: () -> Void

  var body: some View {
    Group {
      switch state {
      case .idle:
        EmptyView()
      case .capturing:
        statusBubble(icon: "camera.shutter.button", label: "Capturing…")
      case .thinking:
        statusBubble(icon: "sparkles", label: "Looking up the lore…", showsSpinner: true)
      case .speaking(let text):
        loreBubble(text: text, isSpeaking: true, showsFollowUp: false)
      case .finished(let text):
        loreBubble(text: text, isSpeaking: false, showsFollowUp: canFollowUp)
      case .error(let message):
        errorBubble(message: message)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: state)
  }

  private func statusBubble(icon: String, label: String, showsSpinner: Bool = false) -> some View {
    HStack(spacing: 10) {
      if showsSpinner {
        ProgressView().tint(.white)
      } else {
        Image(systemName: icon).foregroundColor(.white)
      }
      Text(label)
        .font(.subheadline.weight(.medium))
        .foregroundColor(.white)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(Capsule().fill(Color.black.opacity(0.7)))
    .transition(.opacity)
  }

  private func loreBubble(
    text: String,
    isSpeaking: Bool,
    showsFollowUp: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: isSpeaking ? "speaker.wave.2.fill" : "speaker.wave.2")
          .foregroundColor(.white.opacity(0.8))
        Text(isSpeaking ? "Lore" : "Done")
          .font(.caption.weight(.semibold))
          .foregroundColor(.white.opacity(0.8))
        Spacer()
        Button {
          onDismiss()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundColor(.white.opacity(0.7))
        }
        .buttonStyle(.plain)
      }
      Text(text)
        .font(.body)
        .foregroundColor(.white)
        .fixedSize(horizontal: false, vertical: true)
      if showsFollowUp {
        Button {
          onFollowUp()
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "sparkle.magnifyingglass")
            Text("Tell me more")
              .font(.callout.weight(.semibold))
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
          .background(Capsule().fill(Color.white.opacity(0.18)))
          .foregroundColor(.white)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("follow_up_button")
      }
    }
    .padding(16)
    .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.78)))
    .padding(.horizontal, 16)
    .transition(.move(edge: .bottom).combined(with: .opacity))
  }

  private func errorBubble(message: String) -> some View {
    // Recognize the "You're offline" copy emitted by
    // LoreServiceError.transport and swap in a more readable icon + header.
    // This is a cosmetic sniff, not a protocol change — worst case we fall
    // back to the generic warning.
    let offline = message.lowercased().hasPrefix("you're offline")
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: offline ? "wifi.slash" : "exclamationmark.triangle.fill")
          .foregroundColor(offline ? .white : .yellow)
        Text(offline ? "Offline" : "Lore failed")
          .font(.caption.weight(.semibold))
          .foregroundColor(.white)
        Spacer()
        Button {
          onDismiss()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundColor(.white.opacity(0.7))
        }
        .buttonStyle(.plain)
      }
      Text(message)
        .font(.footnote)
        .foregroundColor(.white.opacity(0.9))
        .fixedSize(horizontal: false, vertical: true)
      Button("Retry", action: onRetry)
        .buttonStyle(.borderedProminent)
        .tint(.white.opacity(0.2))
        .foregroundColor(.white)
    }
    .padding(16)
    .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.82)))
    .padding(.horizontal, 16)
    .transition(.opacity)
  }
}

enum LoreFlowState: Equatable {
  case idle
  case capturing
  case thinking
  case speaking(String)
  case finished(String)
  case error(String)
}
