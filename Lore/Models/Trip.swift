import Foundation
import SwiftData

/// A Trip groups JournalEntries that belong to the same travel session.
///
/// The heuristic for "same session" lives in `JournalStore.resolveTrip(for:)`:
/// a trip ends when either the user crosses into a new country OR more than
/// `JournalStore.tripGapDays` elapse without a new entry. The user doesn't
/// declare trips — they just travel and capture, and the journal organizes
/// itself.
///
/// This is intentionally simple for V1. Edge cases we're not handling yet:
/// cross-country day trips (Luxembourg from Brussels), frequent-flier
/// commutes, road trips that span half a continent. When they become real
/// complaints we'll revisit with a smarter heuristic (e.g., clustering by
/// great-circle distance + time gap).
@Model
final class Trip {
  @Attribute(.unique) var id: UUID
  var startedAt: Date
  /// nil while the trip is "active" — updated every time a new entry is
  /// appended so we can quickly compute "last activity was N days ago"
  /// without scanning the entries collection.
  var lastEntryAt: Date

  /// Human-readable heading shown in the Journal timeline. Generated from
  /// the first entry's placemark + month, e.g. "Barcelona, Spain · Apr 2026".
  /// Stored rather than computed so renaming placemarks later (or an entry
  /// losing its location) doesn't rewrite history.
  var title: String

  /// Stable grouping key. `isoCountryCode` is the "did we cross a border?"
  /// signal for new-trip detection; `primaryCountry` is the human label.
  var primaryCountry: String?
  var isoCountryCode: String?

  @Relationship(deleteRule: .cascade, inverse: \JournalEntry.trip)
  var entries: [JournalEntry] = []

  init(
    title: String,
    primaryCountry: String?,
    isoCountryCode: String?,
    startedAt: Date = .now
  ) {
    self.id = UUID()
    self.title = title
    self.primaryCountry = primaryCountry
    self.isoCountryCode = isoCountryCode
    self.startedAt = startedAt
    self.lastEntryAt = startedAt
  }
}
