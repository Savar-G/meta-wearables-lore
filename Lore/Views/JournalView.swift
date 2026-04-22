import MapKit
import SwiftData
import SwiftUI

/// The Lore Journal. Three views over the same SwiftData store:
///
/// - **Timeline**: entries grouped by Trip, newest first. The default view.
/// - **Map**: all located entries as pins; tapping one opens the detail.
/// - **Search**: free-text filter over transcripts and place names.
///
/// Presented as a sheet from NonStreamView. Wrapped in NavigationStack so
/// tapping a row pushes a detail view.
struct JournalView: View {
  @Environment(\.dismiss) private var dismiss

  /// SwiftData drives the reads. @Query re-fetches automatically whenever
  /// the store changes, so new captures appear without a manual reload.
  @Query(sort: \JournalEntry.createdAt, order: .reverse) private var entries: [JournalEntry]
  @Query(sort: \Trip.lastEntryAt, order: .reverse) private var trips: [Trip]

  @State private var selectedTab: JournalTab = .timeline
  @State private var searchQuery: String = ""

  enum JournalTab: String, CaseIterable, Identifiable {
    case timeline, map, search
    var id: String { rawValue }
    var label: String {
      switch self {
      case .timeline: return "Timeline"
      case .map: return "Map"
      case .search: return "Search"
      }
    }
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Picker("", selection: $selectedTab) {
          ForEach(JournalTab.allCases) { tab in
            Text(tab.label).tag(tab)
          }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.top, 8)

        Group {
          switch selectedTab {
          case .timeline:
            timelineBody
          case .map:
            JournalMapView(entries: entries)
          case .search:
            searchBody
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .navigationTitle("Journal")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  // MARK: - Timeline tab

  @ViewBuilder
  private var timelineBody: some View {
    if entries.isEmpty {
      emptyState(
        icon: "book.closed",
        title: "No entries yet",
        subtitle: "Capture a lore moment and it lands here automatically."
      )
    } else {
      List {
        ForEach(trips) { trip in
          let tripEntries = entries.filter { $0.trip?.id == trip.id }
          if !tripEntries.isEmpty {
            Section {
              ForEach(tripEntries) { entry in
                NavigationLink {
                  JournalEntryDetailView(entry: entry)
                } label: {
                  JournalEntryRow(entry: entry)
                }
              }
            } header: {
              Text(trip.title)
                .textCase(nil)
            }
          }
        }

        // Orphaned entries (no trip) are rare but possible mid-refactor
        // or if a save raced the trip resolver. Surface them so they
        // aren't silently invisible.
        let orphans = entries.filter { $0.trip == nil }
        if !orphans.isEmpty {
          Section("Unsorted") {
            ForEach(orphans) { entry in
              NavigationLink {
                JournalEntryDetailView(entry: entry)
              } label: {
                JournalEntryRow(entry: entry)
              }
            }
          }
        }
      }
      .listStyle(.insetGrouped)
    }
  }

  // MARK: - Search tab

  @ViewBuilder
  private var searchBody: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundColor(.secondary)
        TextField("Search transcripts or places", text: $searchQuery)
          .textFieldStyle(.roundedBorder)
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
        if !searchQuery.isEmpty {
          Button {
            searchQuery = ""
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)

      let filtered = filteredEntries
      if filtered.isEmpty && !searchQuery.isEmpty {
        emptyState(
          icon: "magnifyingglass",
          title: "No matches",
          subtitle: "Try a different word, or the name of a city."
        )
      } else if searchQuery.isEmpty {
        emptyState(
          icon: "text.magnifyingglass",
          title: "Find any lore",
          subtitle: "Search by what was said, or where you were."
        )
      } else {
        List(filtered) { entry in
          NavigationLink {
            JournalEntryDetailView(entry: entry)
          } label: {
            JournalEntryRow(entry: entry)
          }
        }
        .listStyle(.plain)
      }
    }
  }

  private var filteredEntries: [JournalEntry] {
    let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }
    let lowered = query.lowercased()
    return entries.filter { entry in
      if entry.transcript.lowercased().contains(lowered) { return true }
      let placeFields = [
        entry.locality, entry.subLocality, entry.administrativeArea,
        entry.country, entry.areaOfInterest,
      ].compactMap { $0?.lowercased() }
      return placeFields.contains { $0.contains(lowered) }
    }
  }

  // MARK: - Shared pieces

  private func emptyState(icon: String, title: String, subtitle: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 44, weight: .light))
        .foregroundColor(.secondary)
      Text(title)
        .font(.headline)
      Text(subtitle)
        .font(.subheadline)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Timeline row

private struct JournalEntryRow: View {
  let entry: JournalEntry

  var body: some View {
    HStack(spacing: 12) {
      thumbnail
      VStack(alignment: .leading, spacing: 4) {
        if let place = entry.locationSummary {
          Text(place)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
        }
        Text(entry.previewText)
          .font(.footnote)
          .foregroundColor(.secondary)
          .lineLimit(2)
        Text(Self.relativeTime(from: entry.createdAt))
          .font(.caption2)
          .foregroundColor(.secondary)
      }
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private var thumbnail: some View {
    if let data = entry.photoJPEG, let image = UIImage(data: data) {
      Image(uiImage: image)
        .resizable()
        .aspectRatio(contentMode: .fill)
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    } else {
      RoundedRectangle(cornerRadius: 8)
        .fill(Color.secondary.opacity(0.2))
        .frame(width: 52, height: 52)
        .overlay(Image(systemName: "photo").foregroundColor(.secondary))
    }
  }

  private static func relativeTime(from date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: .now)
  }
}

// MARK: - Map tab

private struct JournalMapView: View {
  let entries: [JournalEntry]

  @State private var camera: MapCameraPosition = .automatic
  @State private var selectedEntry: JournalEntry?

  var body: some View {
    Group {
      if locatedEntries.isEmpty {
        VStack(spacing: 12) {
          Image(systemName: "map")
            .font(.system(size: 44, weight: .light))
            .foregroundColor(.secondary)
          Text("No located entries yet")
            .font(.headline)
          Text("Turn on location in Settings and capture a lore moment to see it pinned here.")
            .font(.subheadline)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        Map(position: $camera) {
          ForEach(locatedEntries) { entry in
            // Force-unwrap is safe — `locatedEntries` filtered on these.
            let coord = CLLocationCoordinate2D(
              latitude: entry.latitude!, longitude: entry.longitude!)
            Annotation(entry.locationSummary ?? "Entry", coordinate: coord) {
              Button {
                selectedEntry = entry
              } label: {
                Image(systemName: "sparkles.square.filled.on.square")
                  .font(.title2)
                  .foregroundStyle(.white, .purple)
                  .padding(6)
                  .background(Circle().fill(Color.purple))
                  .overlay(Circle().stroke(.white, lineWidth: 2))
                  .shadow(radius: 3)
              }
              .buttonStyle(.plain)
            }
          }
        }
      }
    }
    .sheet(item: $selectedEntry) { entry in
      NavigationStack {
        JournalEntryDetailView(entry: entry)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Close") { selectedEntry = nil }
            }
          }
      }
    }
  }

  private var locatedEntries: [JournalEntry] {
    entries.filter { $0.latitude != nil && $0.longitude != nil }
  }
}

// MARK: - Detail

struct JournalEntryDetailView: View {
  let entry: JournalEntry

  @StateObject private var speaker = LoreSpeaker()
  @State private var isReplaying: Bool = false
  @State private var shareImage: UIImage?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let data = entry.photoJPEG, let image = UIImage(data: data) {
          Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }

        VStack(alignment: .leading, spacing: 4) {
          if let place = entry.locationSummary {
            Text(place)
              .font(.title3.weight(.semibold))
          }
          HStack(spacing: 6) {
            Text(entry.persona.displayName)
            Text("·")
            Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
          }
          .font(.caption)
          .foregroundColor(.secondary)
        }

        Text(entry.transcript)
          .font(.body)
          .fixedSize(horizontal: false, vertical: true)

        // Full placemark block — useful when the summary hides detail.
        if let fullPlace = fullPlacemarkLines {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(fullPlace, id: \.self) { line in
              Text(line)
                .font(.caption)
                .foregroundColor(.secondary)
            }
          }
          .padding(.top, 4)
        }

        HStack(spacing: 12) {
          Button {
            if isReplaying {
              speaker.stop()
              isReplaying = false
            } else {
              replay()
            }
          } label: {
            HStack(spacing: 8) {
              Image(systemName: isReplaying ? "stop.fill" : "play.fill")
              Text(isReplaying ? "Stop" : "Replay")
                .font(.body.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor))
            .foregroundColor(.white)
          }
          .buttonStyle(.plain)

          Button {
            // Rendering can take a few hundred ms on the main actor —
            // kick to the next run loop so the button's pressed-state
            // animation fires before the share sheet hops in. Feels
            // snappier than a dead button while UIKit works.
            Task { @MainActor in
              shareImage = LoreShareCardRenderer.makeImage(for: entry)
            }
          } label: {
            HStack(spacing: 8) {
              Image(systemName: "square.and.arrow.up")
              Text("Share")
                .font(.body.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
              RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
            )
            .foregroundColor(.accentColor)
          }
          .buttonStyle(.plain)
        }

        Spacer(minLength: 0)
      }
      .padding(16)
    }
    .navigationTitle("Entry")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(item: Binding(
      get: { shareImage.map { ShareImage(image: $0) } },
      set: { if $0 == nil { shareImage = nil } }
    )) { wrapper in
      ShareSheet(items: [wrapper.image])
    }
  }

  /// Identifiable wrapper so `sheet(item:)` can diff-present when the
  /// rendered image is ready. Without this we'd need a separate
  /// `@State var isSharing: Bool` and race the image being nil on open.
  private struct ShareImage: Identifiable {
    let id = UUID()
    let image: UIImage
  }

  private var fullPlacemarkLines: [String]? {
    let candidates: [(String, String?)] = [
      ("Landmark", entry.areaOfInterest),
      ("Neighborhood", entry.subLocality),
      ("City", entry.locality),
      ("Region", entry.administrativeArea),
      ("Country", entry.country),
    ]
    let lines = candidates
      .compactMap { label, value -> String? in
        guard let value, !value.isEmpty else { return nil }
        return "\(label): \(value)"
      }
    return lines.isEmpty ? nil : lines
  }

  private func replay() {
    do {
      try speaker.prepareAudioSession()
    } catch {
      NSLog("[Lore] Replay audio session setup failed: \(error)")
    }
    // Pick the language the entry was originally in so we don't try to
    // speak Japanese transcripts with an en-US voice. Entries from before
    // the language picker shipped have languageCode == nil; those fall
    // through to the speaker's default (English) which is the only voice
    // they were ever spoken with.
    if let code = entry.languageCode,
      let language = LoreLanguage.allCases.first(where: { $0.voiceCode == code })
    {
      speaker.setLanguage(language)
    }
    isReplaying = true
    speaker.speak(entry.transcript) {
      isReplaying = false
    }
  }
}
