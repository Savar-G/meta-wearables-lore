import Foundation
import SwiftData

/// A single captured lore moment: photo + transcript + where + when + who
/// narrated it. Persisted via SwiftData so the Journal view and prompt
/// memory injection both read from the same source of truth.
///
/// Storage notes:
/// - `photoJPEG` is `@Attribute(.externalStorage)` so the JPEG lives as a
///   separate file instead of bloating the SQLite store. 100 entries at
///   ~1 MB each inside SQLite would make queries miserable.
/// - Placemark fields are denormalized (copied at save time) rather than
///   referenced. This lets us query and group without reverse-geocoding
///   again, and preserves context if the user later deletes their
///   location history.
/// - `personaRawValue` and `languageCode` are stored as String, not enums,
///   because SwiftData on iOS 17 doesn't love persisting custom enum
///   types. The computed `persona` accessor maps back.
@Model
final class JournalEntry {
  @Attribute(.unique) var id: UUID
  var createdAt: Date
  var transcript: String

  /// Which LorePersona narrated this entry. Stored as rawValue; access
  /// through the `persona` computed property for a typed read.
  var personaRawValue: String

  /// BCP-47 language code (e.g., "en-US", "ja-JP") the response was in.
  /// Optional because pre-Phase-4 entries don't have this information.
  /// Also used by the Journal detail view to pick a TTS voice on replay.
  var languageCode: String?

  /// JPEG bytes of the captured frame. Nil only if we somehow ended up
  /// with transcript text but no image (shouldn't happen in normal flow).
  @Attribute(.externalStorage) var photoJPEG: Data?

  // MARK: - Denormalized placemark fields
  // Copied from CLPlacemark at save time so the Journal view can filter,
  // group, and display without reloading CoreLocation.

  var locality: String?
  var subLocality: String?
  var administrativeArea: String?
  var country: String?
  var isoCountryCode: String?
  var areaOfInterest: String?
  var latitude: Double?
  var longitude: Double?

  var trip: Trip?

  init(
    transcript: String,
    personaRawValue: String,
    languageCode: String? = nil,
    photoJPEG: Data? = nil,
    locality: String? = nil,
    subLocality: String? = nil,
    administrativeArea: String? = nil,
    country: String? = nil,
    isoCountryCode: String? = nil,
    areaOfInterest: String? = nil,
    latitude: Double? = nil,
    longitude: Double? = nil,
    trip: Trip? = nil,
    createdAt: Date = .now
  ) {
    self.id = UUID()
    self.createdAt = createdAt
    self.transcript = transcript
    self.personaRawValue = personaRawValue
    self.languageCode = languageCode
    self.photoJPEG = photoJPEG
    self.locality = locality
    self.subLocality = subLocality
    self.administrativeArea = administrativeArea
    self.country = country
    self.isoCountryCode = isoCountryCode
    self.areaOfInterest = areaOfInterest
    self.latitude = latitude
    self.longitude = longitude
    self.trip = trip
  }

  /// Typed accessor — falls back to `.narrator` if raw value was written
  /// by a build of the app that knew a persona this one doesn't.
  var persona: LorePersona {
    LorePersona(rawValue: personaRawValue) ?? .narrator
  }

  /// "Where this happened" summary for list cells. Prefers the named
  /// landmark when available, then neighborhood, then city. Returns nil
  /// for entries captured without location permission.
  var locationSummary: String? {
    let parts = [areaOfInterest, subLocality, locality]
      .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    return parts.first
  }

  /// First sentence (or first 120 chars) of the transcript for the
  /// timeline preview. Full transcript is shown in detail view.
  var previewText: String {
    let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    // Sentence terminators + space: end of sentence 1. Fallback to char cap.
    if let range = text.range(of: #"[.!?…](\s|$)"#, options: .regularExpression),
       range.upperBound < text.endIndex
    {
      return String(text[..<range.upperBound]).trimmingCharacters(in: .whitespaces)
    }
    if text.count > 120 {
      let endIndex = text.index(text.startIndex, offsetBy: 120)
      return String(text[..<endIndex]) + "…"
    }
    return text
  }
}
