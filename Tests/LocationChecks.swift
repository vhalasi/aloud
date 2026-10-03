import CoreLocation

@main
struct LocationChecks {
    @MainActor static func main() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func fix(accuracy: Double = 25, age: Double = 10, latitude: Double = 59.3309) -> CLLocation {
            CLLocation(coordinate: .init(latitude: latitude, longitude: 18.0580), altitude: 0,
                       horizontalAccuracy: accuracy, verticalAccuracy: -1,
                       timestamp: now.addingTimeInterval(-age))
        }
        assert(PlacesLocation.usable(fix(), allowApproximate: false, now: now))
        assert(!PlacesLocation.usable(fix(accuracy: 2000), allowApproximate: false, now: now))
        assert(PlacesLocation.usable(fix(accuracy: 2000), allowApproximate: true, now: now))
        for invalid in [fix(accuracy: -1), fix(accuracy: .infinity), fix(age: 60), fix(age: -10), fix(latitude: 91)] {
            assert(!PlacesLocation.usable(invalid, allowApproximate: true, now: now))
        }
        let precise = PlacesLocation.toolResult(for: fix(), reducedAccuracy: false, now: now)
        assert(precise["latitude"] as? Double == 59.3309)
        assert(precise["horizontal_accuracy_metres"] as? Double == 25)
        assert(precise["age_seconds"] as? Double == 10)
        assert(precise["is_approximate"] as? Bool == false)
        let coarse = PlacesLocation.toolResult(for: fix(accuracy: 2000), reducedAccuracy: false, now: now)
        assert(coarse["is_approximate"] as? Bool == true)
        let reduced = PlacesLocation.toolResult(for: fix(), reducedAccuracy: true, now: now)
        assert(reduced["is_approximate"] as? Bool == true)
        assert(reduced["accuracy_authorization"] as? String == "approximate")
        _ = try JSONSerialization.data(withJSONObject: precise)
        _ = try JSONSerialization.data(withJSONObject: coarse)
        print("Location freshness, accuracy and tool payload checks passed")
    }
}
