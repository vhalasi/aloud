import Foundation

/// Prototype tuning, expressed in metres and seconds.
struct ProximitySignal {
    static let demoDistance: Double = 1
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

/// A camera-centred measurement, never proof of an obstacle in the user's walking path.
struct ProximitySnapshot {
    let distance: Float?
    let sampledAt: TimeInterval
    let observedAt: Date
    let source: String
    let isRunning: Bool
    let isDemo: Bool

    func validDistance(now: TimeInterval) -> Float? {
        guard isRunning, !isDemo, now >= sampledAt, now - sampledAt <= 0.6,
              let distance, distance.isFinite, distance > 0, distance <= 8 else { return nil }
        return distance
    }

    func context(now: TimeInterval) -> [String: Any] {
        let measured = validDistance(now: now)
        var result: [String: Any] = [
            "type": "proximity_sensor", "source": source,
            "status": isDemo ? "simulation_not_real" : !isRunning ? "stopped" : measured == nil ? "unavailable" : "measured",
            "sample_age_ms": Int(max(0, now - sampledAt) * 1000),
            "observed_at": ISO8601DateFormatter().string(from: observedAt),
            "scope": "central camera view, not walking direction or full-scene collision detection",
            "note": "No reading does not mean clear. A depth reading cannot establish traffic or crossing safety."
        ]
        if let measured {
            result["distance_metres"] = (Double(measured) * 10).rounded() / 10
            result["haptic_cue_active"] = ProximitySignal.at(distance: measured) != nil
            result["valid_for_ms"] = Int(max(0, 0.6 - (now - sampledAt)) * 1000)
        }
        return result
    }
}

/// Debounce transitions and coalesce sensor changes before sending them to the voice model.
struct ProximityReporter {
    private(set) var latest: ProximitySnapshot?
    private var candidate = ""
    private var candidateSince: TimeInterval = 0
    private var sentBand = ""
    private var sentDistance: Float?
    private var lastSent: TimeInterval = -.infinity
    private var lastWarning: TimeInterval = -.infinity

    mutating func update(_ snapshot: ProximitySnapshot) { latest = snapshot }

    func currentContext(now: TimeInterval) -> [String: Any] {
        latest?.context(now: now) ?? ["type": "proximity_sensor", "status": "unavailable",
                                    "note": "No depth reading is available. This does not mean the path is clear."]
    }

    mutating func nextEvent(now: TimeInterval) -> [String: Any]? {
        guard let latest else { return nil }
        let distance = latest.validDistance(now: now)
        let band: String
        if let distance {
            // Wider exit thresholds keep a stationary object at the boundary from chattering.
            if distance < 0.6 || (sentBand == "very_close" && distance < 0.75) { band = "very_close" }
            else if distance < 1.2 || (sentBand == "nearby" && distance < 1.35) { band = "nearby" }
            else { band = "farther" }
        } else { band = latest.context(now: now)["status"] as! String }
        if candidate != band { candidate = band; candidateSince = now }
        guard now - candidateSince >= 0.3, now - lastSent >= 2 else { return nil }
        let changedDistance = distance.flatMap { d in sentDistance.map { abs(d - $0) >= 0.25 } } ?? false
        guard band != sentBand || (changedDistance && band != "farther") else { return nil }
        var event = currentContext(now: now)
        let age = now - lastSent
        let trend: String
        if let distance, let sentDistance, age <= 5 {
            trend = distance < sentDistance - 0.15 ? "decreasing" : distance > sentDistance + 0.15 ? "increasing" : "steady"
        } else { trend = "unknown" }
        let closer = band == "very_close" && sentBand != "very_close"
        let shouldWarn = (band == "nearby" || band == "very_close") &&
            (closer || (now - lastWarning >= 8 && (band != sentBand || trend == "decreasing")))
        event["distance_band"] = band
        event["distance_trend"] = trend
        event["should_warn"] = shouldWarn
        event["trend_note"] = "A change can come from the phone turning or an object moving; it does not prove the user is walking toward it."
        if shouldWarn { lastWarning = now }
        sentBand = band; sentDistance = distance; lastSent = now
        return event
    }
}
