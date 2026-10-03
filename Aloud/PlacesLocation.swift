import CoreLocation

@MainActor
final class PlacesLocation: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var pending: CheckedContinuation<CLLocation, Error>?
    private var pendingID: UUID?
    private var allowsApproximate = false
    private var timeout: Task<Void, Never>?
    var authorization: CLAuthorizationStatus { manager.authorizationStatus }
    var reducedAccuracy: Bool { manager.accuracyAuthorization == .reducedAccuracy }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func current(requestPermission: Bool = false, allowApproximate: Bool = false) async throws -> CLLocation {
        guard pending == nil else { throw LocationError.busy }
        try Task.checkCancellation()
        let authorized = authorization == .authorizedAlways || authorization == .authorizedWhenInUse
        if authorized, let location = manager.location, Self.usable(location, allowApproximate: allowApproximate) { return location }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                pendingID = id
                allowsApproximate = allowApproximate
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled, self?.pendingID == id else { return }
                    self?.finish(.failure(LocationError.unavailable))
                }
                switch authorization {
                case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
                case .notDetermined where requestPermission: manager.requestWhenInUseAuthorization()
                default: finish(.failure(LocationError.denied))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.pendingID == id else { return }
                self?.finish(.failure(CancellationError()))
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard pending != nil else { return }
        switch authorization {
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        case .denied, .restricted: finish(.failure(LocationError.denied))
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard pending != nil else { return }
        guard let location = locations.last(where: { Self.usable($0, allowApproximate: allowsApproximate) }) else {
            finish(.failure(reducedAccuracy ? LocationError.approximate : LocationError.unavailable)); return
        }
        finish(.success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(LocationError.unavailable))
    }

    static func usable(_ location: CLLocation, allowApproximate: Bool, now: Date = Date()) -> Bool {
        CLLocationCoordinate2DIsValid(location.coordinate) &&
        location.horizontalAccuracy.isFinite && location.horizontalAccuracy >= 0 &&
        (allowApproximate || location.horizontalAccuracy <= 500) &&
        now.timeIntervalSince(location.timestamp) >= -5 && now.timeIntervalSince(location.timestamp) < 60
    }

    static func toolResult(for location: CLLocation, reducedAccuracy: Bool, now: Date = Date()) -> [String: Any] {
        ["source": "iPhone Core Location", "latitude": location.coordinate.latitude,
         "longitude": location.coordinate.longitude,
         "horizontal_accuracy_metres": location.horizontalAccuracy,
         "accuracy_authorization": reducedAccuracy ? "approximate" : "precise",
         "timestamp": ISO8601DateFormatter().string(from: location.timestamp),
         "age_seconds": max(0, now.timeIntervalSince(location.timestamp)),
         "is_approximate": reducedAccuracy || location.horizontalAccuracy > 100,
         "note": "This is the phone's measured location, not a camera-based guess. Accuracy is an uncertainty radius; do not infer an exact building, entrance, floor or safe walking route. If no address is returned, do not invent one."]
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        timeout?.cancel(); timeout = nil
        let continuation = pending; pending = nil; pendingID = nil
        manager.stopUpdatingLocation()
        continuation?.resume(with: result)
    }

    enum LocationError: LocalizedError {
        case denied, unavailable, busy, approximate
        var code: String {
            switch self {
            case .denied: return "permission_denied"
            case .unavailable: return "location_unavailable"
            case .busy: return "location_busy"
            case .approximate: return "precise_location_needed"
            }
        }
        var errorDescription: String? {
            switch self {
            case .denied: return "Location access is off. Enable location for Aloud in Settings, then restart AI."
            case .unavailable: return "A recent location fix is unavailable. Move near a window or outdoors and ask again."
            case .busy: return "Another location request is in progress. Try again shortly."
            case .approximate: return "Only approximate location is available. Enable Precise Location for Aloud in Settings for nearby searches."
            }
        }
    }
}
