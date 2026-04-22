import CoreLocation
import Foundation
import SwiftData

/// Thin façade over SwiftData's ModelContext that captures all journal
/// concerns in one place: saving a new entry, resolving which Trip it
/// belongs to, and serving up recent entries for memory injection into
/// the prompt.
///
/// Kept on @MainActor because ModelContext isn't Sendable and the Journal
/// view + the ViewModel both live on the main actor. All writes are
/// immediate `context.save()` calls — the journal is tiny (text + thumb
/// refs), no batching needed.
@MainActor
final class JournalStore {
  /// Two consecutive entries in the same country more than this many days
  /// apart end one trip and start another. Five days is long enough that
  /// weekend trips home from the same hotel don't fracture into mini-trips,
  /// short enough that a new vacation to the same country reads as a new
  /// trip.
  static let tripGapDays: Double = 5

  private let context: ModelContext

  init(context: ModelContext) {
    self.context = context
  }

  // MARK: - Writes

  /// Persist a lore capture. Places it into the active Trip (creating one
  /// if necessary) and flushes the context immediately so the Journal
  /// view reflects it on the next read.
  @discardableResult
  func save(
    transcript: String,
    persona: LorePersona,
    languageCode: String?,
    photoJPEG: Data?,
    placemark: CLPlacemark?,
    now: Date = .now
  ) -> JournalEntry? {
    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    // Empty lore is never worth a journal slot. Fails silently — the VM
    // treats a nil save as a no-op.
    guard !trimmed.isEmpty else { return nil }

    let entry = JournalEntry(
      transcript: trimmed,
      personaRawValue: persona.rawValue,
      languageCode: languageCode,
      photoJPEG: photoJPEG,
      locality: placemark?.locality,
      subLocality: placemark?.subLocality,
      administrativeArea: placemark?.administrativeArea,
      country: placemark?.country,
      isoCountryCode: placemark?.isoCountryCode,
      areaOfInterest: placemark?.areasOfInterest?.first,
      latitude: placemark?.location?.coordinate.latitude,
      longitude: placemark?.location?.coordinate.longitude,
      createdAt: now
    )

    let trip = resolveTrip(for: placemark, now: now)
    entry.trip = trip
    trip.lastEntryAt = now
    context.insert(entry)

    do {
      try context.save()
    } catch {
      NSLog("[Lore] JournalStore.save failed: \(error)")
    }
    return entry
  }

  // MARK: - Reads

  /// Most recent entries within the active trip, newest first. Used for
  /// the "memory" context lines injected into the next prompt so the
  /// model doesn't repeat itself within a trip.
  func recentEntriesForMemory(limit: Int = 3) -> [JournalEntry] {
    guard let trip = activeTrip() else { return [] }
    let tripID = trip.id
    var descriptor = FetchDescriptor<JournalEntry>(
      predicate: #Predicate { entry in
        entry.trip?.id == tripID
      },
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    descriptor.fetchLimit = limit
    do {
      return try context.fetch(descriptor)
    } catch {
      NSLog("[Lore] recentEntriesForMemory fetch failed: \(error)")
      return []
    }
  }

  /// One-line summaries of recent memories for slotting into the persona
  /// system prompt. Kept terse on purpose — we're budgeting tokens.
  ///
  /// Example output lines:
  /// - "Already covered 2h ago near Sagrada Familia: Gaudí's trapped..."
  /// - "Already covered yesterday in Eixample: The block pattern was..."
  func memoryContextLines(limit: Int = 3) -> [String] {
    let entries = recentEntriesForMemory(limit: limit)
    guard !entries.isEmpty else { return [] }
    var lines: [String] = [
      "Already covered on this trip (avoid repeating — find a new angle):"
    ]
    let now = Date()
    for entry in entries {
      let when = Self.relativeTime(from: entry.createdAt, to: now)
      let where_ = entry.locationSummary.map { " near \($0)" } ?? ""
      // Only the first ~80 chars of the prior transcript — we're giving
      // the model a "what did I already say" reminder, not re-feeding it
      // the old answer verbatim.
      let preview = String(entry.previewText.prefix(80))
      lines.append("- \(when)\(where_): \"\(preview)\"")
    }
    return lines
  }

  /// All entries, newest first. Used by the Journal timeline view.
  func allEntries() -> [JournalEntry] {
    let descriptor = FetchDescriptor<JournalEntry>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    return (try? context.fetch(descriptor)) ?? []
  }

  /// All trips, newest first. Used to group the timeline.
  func allTrips() -> [Trip] {
    let descriptor = FetchDescriptor<Trip>(
      sortBy: [SortDescriptor(\.lastEntryAt, order: .reverse)]
    )
    return (try? context.fetch(descriptor)) ?? []
  }

  // MARK: - Trip resolution

  /// Returns the Trip a new entry captured *now* should belong to, creating
  /// one when the heuristic decides this is a new travel session.
  ///
  /// Heuristic (ordered):
  /// 1. No active trip at all → new trip.
  /// 2. New entry has a country AND it differs from the active trip's
  ///    country → new trip. Crossing a border is always a new trip.
  /// 3. Active trip's last entry was >= `tripGapDays` ago → new trip.
  /// 4. Otherwise → append to active trip.
  ///
  /// Entries without country info (no location permission, no GPS) don't
  /// create new trips on their own — they just attach to whatever is
  /// active or start a "Journal" trip if none exists.
  func resolveTrip(for placemark: CLPlacemark?, now: Date) -> Trip {
    let entryCountry = placemark?.country
    let entryISO = placemark?.isoCountryCode

    if let active = activeTrip() {
      // Country change: only bail if we actually know the new country.
      if let entryISO, let activeISO = active.isoCountryCode, entryISO != activeISO {
        return makeTrip(for: placemark, now: now)
      }
      // Gap check: if too long has passed, start a new trip even in same country.
      let gap = now.timeIntervalSince(active.lastEntryAt)
      if gap >= Self.tripGapDays * 86_400 {
        return makeTrip(for: placemark, now: now)
      }
      // Backfill country on an existing trip that started without one —
      // e.g., first entry had no location, second one does. Title stays
      // as-is so the timeline doesn't reshuffle retroactively.
      if active.isoCountryCode == nil, entryISO != nil {
        active.primaryCountry = entryCountry
        active.isoCountryCode = entryISO
      }
      return active
    }

    return makeTrip(for: placemark, now: now)
  }

  private func activeTrip() -> Trip? {
    var descriptor = FetchDescriptor<Trip>(
      sortBy: [SortDescriptor(\.lastEntryAt, order: .reverse)]
    )
    descriptor.fetchLimit = 1
    return try? context.fetch(descriptor).first
  }

  private func makeTrip(for placemark: CLPlacemark?, now: Date) -> Trip {
    let title = Self.makeTripTitle(for: placemark, date: now)
    let trip = Trip(
      title: title,
      primaryCountry: placemark?.country,
      isoCountryCode: placemark?.isoCountryCode,
      startedAt: now
    )
    context.insert(trip)
    return trip
  }

  private static func makeTripTitle(for placemark: CLPlacemark?, date: Date) -> String {
    let monthFormatter = DateFormatter()
    monthFormatter.dateFormat = "MMM yyyy"
    let month = monthFormatter.string(from: date)

    let place: String
    if let locality = placemark?.locality, let country = placemark?.country {
      place = "\(locality), \(country)"
    } else if let country = placemark?.country {
      place = country
    } else if let locality = placemark?.locality {
      place = locality
    } else {
      place = "Untitled Trip"
    }
    return "\(place) · \(month)"
  }

  /// "2h ago", "yesterday", "Mon", "Apr 12". Lightweight — no need for
  /// RelativeDateTimeFormatter's locale-aware output here since we only
  /// use this for an ephemeral prompt context line.
  private static func relativeTime(from date: Date, to now: Date) -> String {
    let interval = now.timeIntervalSince(date)
    if interval < 60 { return "moments ago" }
    if interval < 3_600 {
      let mins = Int(interval / 60)
      return "\(mins)m ago"
    }
    if interval < 86_400 {
      let hours = Int(interval / 3_600)
      return "\(hours)h ago"
    }
    let days = Int(interval / 86_400)
    if days == 1 { return "yesterday" }
    if days < 7 { return "\(days) days ago" }
    let df = DateFormatter()
    df.dateFormat = "MMM d"
    return df.string(from: date)
  }
}
