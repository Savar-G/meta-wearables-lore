import CoreLocation
import Foundation

/// Source of truth for "where is the user right now," used by the lore
/// pipeline to ground stories in the actual place rather than whatever the
/// model guesses from pixels alone.
///
/// Why it's structured this way:
/// - The SDK streams locations often; `CLGeocoder` is rate-limited by Apple
///   (~1 req/min in practice) and costs cycles. So we cache the last
///   placemark and only re-geocode when the user has actually moved a
///   meaningful distance, or enough time has passed that it's worth
///   re-checking (e.g., walking from one neighborhood into another).
/// - Accuracy is intentionally coarse: `.hundredMeters` is plenty for
///   "what city are you in" and saves battery vs. `.bestForNavigation`.
/// - This is a soft feature. Denied permission, no GPS fix, offline —
///   all fall through to an empty `contextLines` array, and the lore
///   pipeline continues to work with the image alone.
@MainActor
final class LoreLocationProvider: NSObject, ObservableObject {
  @Published private(set) var placemark: CLPlacemark?
  @Published private(set) var authorizationStatus: CLAuthorizationStatus

  private let manager = CLLocationManager()
  private let geocoder = CLGeocoder()

  /// Anchor used for throttling. We re-geocode when the current location is
  /// more than `Self.minGeocodeDistanceMeters` from this point, or when
  /// `Self.minGeocodeInterval` has elapsed.
  private var lastGeocodedLocation: CLLocation?
  private var lastGeocodeDate: Date?
  private var isGeocodingInFlight = false

  /// Tuning knobs. 100m + 5min hits a sweet spot: crossing a city block
  /// won't spam geocoder, but stepping into a new neighborhood or resuming
  /// after a break does refresh the context.
  private static let minGeocodeDistanceMeters: CLLocationDistance = 100
  private static let minGeocodeInterval: TimeInterval = 300

  override init() {
    self.authorizationStatus = manager.authorizationStatus
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    manager.distanceFilter = Self.minGeocodeDistanceMeters / 2  // notify ~2x faster than we'd geocode
  }

  /// Kick off authorization + updates. Idempotent. Safe to call every time
  /// the user starts a streaming session — if already authorized, this is
  /// effectively a no-op.
  func start() {
    switch authorizationStatus {
    case .notDetermined:
      manager.requestWhenInUseAuthorization()
    case .authorizedWhenInUse, .authorizedAlways:
      manager.startUpdatingLocation()
    case .denied, .restricted:
      // Nothing to do — the feature is optional. Log once so the hardware
      // debug loop surfaces why context-grounding isn't working.
      NSLog("[Lore] Location denied/restricted; skipping location context")
    @unknown default:
      break
    }
  }

  /// Stop updates + cancel any pending geocode. Called when the stream
  /// session ends so we aren't draining battery in the background.
  func stop() {
    manager.stopUpdatingLocation()
    geocoder.cancelGeocode()
    isGeocodingInFlight = false
  }

  /// Formatted context strings to slot into the persona's system prompt.
  /// Returns an empty array when we have no placemark yet (or when the
  /// user has denied location). Keep these short — they cost tokens on
  /// every request.
  var contextLines: [String] {
    guard let placemark else { return [] }
    var lines: [String] = []

    // Primary locale line: "Barcelona, Catalonia, Spain" — skip empty
    // components so we don't emit weird ", , Germany" strings.
    let regionParts = [
      placemark.locality,
      placemark.administrativeArea,
      placemark.country,
    ].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    if !regionParts.isEmpty {
      lines.append("User's approximate location: \(regionParts.joined(separator: ", ")).")
    }

    // Neighborhood is often the highest-signal context for urban shots —
    // "Shoreditch" beats "London" for lore.
    if let subLocality = placemark.subLocality?.trimmingCharacters(in: .whitespaces),
      !subLocality.isEmpty,
      subLocality != placemark.locality
    {
      lines.append("Neighborhood: \(subLocality).")
    }

    // Apple populates `areasOfInterest` with named POIs when the coordinate
    // is close to one. When present, this is gold — it tells the model
    // "the user is standing next to X" without the model having to guess
    // from the image alone.
    if let area = placemark.areasOfInterest?.first?.trimmingCharacters(in: .whitespaces),
      !area.isEmpty
    {
      lines.append("Likely nearby landmark: \(area).")
    }

    return lines
  }

  // MARK: - Private

  /// Decide whether a newly-received CLLocation is "different enough" to
  /// warrant another reverse-geocode call. This is the hot path — runs on
  /// every location update.
  private func shouldGeocode(for location: CLLocation) -> Bool {
    if isGeocodingInFlight { return false }
    guard let last = lastGeocodedLocation, let date = lastGeocodeDate else {
      return true  // Never geocoded — do it now.
    }
    let distance = location.distance(from: last)
    let elapsed = Date().timeIntervalSince(date)
    return distance >= Self.minGeocodeDistanceMeters
      || elapsed >= Self.minGeocodeInterval
  }

  private func performGeocode(for location: CLLocation) {
    isGeocodingInFlight = true
    geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.isGeocodingInFlight = false
        if let error {
          // A CLError.network or .geocodeFoundNoResult is normal — don't
          // blow up, just leave the previous placemark in place.
          NSLog("[Lore] Reverse geocode failed: \(error.localizedDescription)")
          return
        }
        guard let placemark = placemarks?.first else { return }
        self.placemark = placemark
        self.lastGeocodedLocation = location
        self.lastGeocodeDate = Date()
      }
    }
  }
}

// MARK: - CLLocationManagerDelegate

extension LoreLocationProvider: CLLocationManagerDelegate {
  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.authorizationStatus = status
      if status == .authorizedWhenInUse || status == .authorizedAlways {
        manager.startUpdatingLocation()
      }
    }
  }

  nonisolated func locationManager(
    _ manager: CLLocationManager,
    didUpdateLocations locations: [CLLocation]
  ) {
    guard let latest = locations.last else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      guard self.shouldGeocode(for: latest) else { return }
      self.performGeocode(for: latest)
    }
  }

  nonisolated func locationManager(
    _ manager: CLLocationManager,
    didFailWithError error: Error
  ) {
    // Transient failures are common outdoors (tunnels, poor sky view).
    // Log once; the next successful update will recover.
    NSLog("[Lore] Location manager error: \(error.localizedDescription)")
  }
}
