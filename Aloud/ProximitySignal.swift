import Foundation

/// Prototype tuning, expressed in metres and seconds.
struct ProximitySignal {
    let interval: TimeInterval
    let intensity: Double

    static func at(distance: Float) -> ProximitySignal? {
        guard distance.isFinite, distance > 0, distance < 2.5 else { return nil }
        let closeness = Double((2.5 - max(distance, 0.4)) / 2.1)
        return ProximitySignal(
            interval: 0.85 - 0.73 * closeness,
            intensity: 0.35 + 0.65 * closeness
        )
    }
}

/// A lower percentile favors nearby surfaces without trusting a single noisy pixel.
/// This is a central-view proximity cue, not full-scene collision detection.
enum DepthEstimate {
    static func metres(samples: [Float], totalCount: Int) -> Float? {
        let valid = samples.filter { $0.isFinite && $0 > 0 && $0 <= 8 }.sorted()
        guard totalCount > 0, valid.count >= max(8, totalCount / 4) else { return nil }
        return valid[Int(Double(valid.count - 1) * 0.2)]
    }
}
