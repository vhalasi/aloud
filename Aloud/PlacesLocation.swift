import CoreLocation

@MainActor
final class PlacesLocation: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var pending: CheckedContinuation<CLLocation, Error>?
    private var timeout: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func current(requestPermission: Bool = false) async throws -> CLLocation {
        guard pending == nil else { throw LocationError.busy }
        try Task.checkCancellation()
        let authorization = manager.authorizationStatus
        let authorized = authorization == .authorizedAlways || authorization == .authorizedWhenInUse
        if authorized, let location = manager.location, Self.usable(location) { return location }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(LocationError.unavailable))
                }
                switch manager.authorizationStatus {
                case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
                case .notDetermined where requestPermission: manager.requestWhenInUseAuthorization()
                default: finish(.failure(LocationError.denied))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard pending != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        case .denied, .restricted: finish(.failure(LocationError.denied))
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last(where: Self.usable) else {
            finish(.failure(LocationError.unavailable)); return
        }
        finish(.success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(LocationError.unavailable))
    }

    private static func usable(_ location: CLLocation) -> Bool {
        location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 500 &&
        abs(location.timestamp.timeIntervalSinceNow) < 60
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        timeout?.cancel(); timeout = nil
        let continuation = pending; pending = nil
        manager.stopUpdatingLocation()
        continuation?.resume(with: result)
    }

    enum LocationError: LocalizedError {
        case denied, unavailable, busy
        var errorDescription: String? {
            switch self {
            case .denied: return "Location access is off. Enable it for Aloud in Settings to find nearby places."
            case .unavailable: return "A recent, accurate location is unavailable. Try again outdoors."
            case .busy: return "Another location request is in progress. Try again shortly."
            }
        }
    }
}
