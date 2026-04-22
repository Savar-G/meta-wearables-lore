import SwiftUI
import UIKit

/// Render a JournalEntry as a shareable image (Instagram-post-ready 4:5
/// aspect). Composed in SwiftUI, rasterized via `ImageRenderer` (iOS 16+).
///
/// Intentionally opinionated design: dark background, large headline, photo
/// up top, transcript below, a small "Told by Lore" footer. The point is a
/// single-glance "this looks nice, I'd post this" — not a configurable
/// template.
///
/// Rendered off-screen at 1080pt wide (3x scale → 3240px) so the output
/// holds up on Retina displays and Instagram's aggressive recompression.
struct LoreShareCard: View {
  let entry: JournalEntry

  /// Point width of the rendered card. 1080 matches Instagram post width
  /// and keeps math simple downstream (height clamps to 1350 for 4:5 post
  /// ratio when content fits, otherwise grows).
  static let width: CGFloat = 1080

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      photoBlock
      contentBlock
    }
    .frame(width: Self.width)
    .background(Color.black)
  }

  @ViewBuilder
  private var photoBlock: some View {
    if let data = entry.photoJPEG, let image = UIImage(data: data) {
      Image(uiImage: image)
        .resizable()
        .aspectRatio(contentMode: .fill)
        .frame(width: Self.width, height: Self.width * 3 / 4)  // 4:3 hero
        .clipped()
    } else {
      Rectangle()
        .fill(Color(white: 0.12))
        .frame(width: Self.width, height: Self.width * 3 / 4)
        .overlay(
          Image(systemName: "photo")
            .font(.system(size: 80))
            .foregroundColor(.white.opacity(0.3))
        )
    }
  }

  private var contentBlock: some View {
    VStack(alignment: .leading, spacing: 20) {
      if let place = entry.locationSummary {
        HStack(spacing: 10) {
          Image(systemName: "mappin.circle.fill")
            .foregroundColor(.white.opacity(0.7))
            .font(.system(size: 28))
          Text(place)
            .font(.system(size: 34, weight: .bold))
            .foregroundColor(.white)
            .lineLimit(2)
        }
      }

      Text(entry.transcript)
        .font(.system(size: 28, weight: .regular))
        .foregroundColor(.white.opacity(0.92))
        .lineSpacing(6)
        .fixedSize(horizontal: false, vertical: true)

      Divider()
        .background(Color.white.opacity(0.15))

      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("TOLD BY LORE")
            .font(.system(size: 14, weight: .heavy))
            .tracking(2)
            .foregroundColor(.white.opacity(0.5))
          Text(entry.persona.displayName)
            .font(.system(size: 20, weight: .semibold))
            .foregroundColor(.white.opacity(0.85))
        }
        Spacer()
        Text(entry.createdAt.formatted(date: .abbreviated, time: .omitted))
          .font(.system(size: 18, weight: .medium))
          .foregroundColor(.white.opacity(0.6))
      }
    }
    .padding(.horizontal, 56)
    .padding(.top, 40)
    .padding(.bottom, 48)
  }
}

// MARK: - Rendering

enum LoreShareCardRenderer {
  /// Rasterize a card view to a UIImage. Returns nil if rendering fails
  /// (e.g., the view produced no image, which shouldn't happen in normal
  /// flow but UIKit APIs allow for it).
  ///
  /// Uses `ImageRenderer` (iOS 16+) rather than the older UIGraphicsBegin
  /// APIs so SwiftUI layout works normally. Scale 3 for crisp output on
  /// any device the user shares to.
  @MainActor
  static func makeImage(for entry: JournalEntry) -> UIImage? {
    let renderer = ImageRenderer(content: LoreShareCard(entry: entry))
    renderer.scale = 3
    return renderer.uiImage
  }
}

// MARK: - Share sheet wrapper

/// Minimal UIActivityViewController bridge. SwiftUI's ShareLink doesn't
/// accept a UIImage payload directly on iOS 17, and we want the image
/// available to Instagram / Messages / Save to Photos with one sheet.
struct ShareSheet: UIViewControllerRepresentable {
  let items: [Any]
  var excluded: [UIActivity.ActivityType] = []

  func makeUIViewController(context: Context) -> UIActivityViewController {
    let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
    vc.excludedActivityTypes = excluded
    return vc
  }

  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
