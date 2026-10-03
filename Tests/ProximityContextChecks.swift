import Foundation

@main struct ProximityContextChecks {
    static func main() {
        func snapshot(_ distance: Float?, _ now: Double, demo: Bool = false, running: Bool = true) -> ProximitySnapshot {
            ProximitySnapshot(distance: distance, sampledAt: now, observedAt: Date(timeIntervalSince1970: 1_700_000_000 + now),
                              source: "front_truedepth", isRunning: running, isDemo: demo)
        }
        var reporter = ProximityReporter()
        func sample(_ distance: Float?, _ now: Double, demo: Bool = false) -> [String: Any]? {
            reporter.update(snapshot(distance, now, demo: demo))
            return reporter.nextEvent(now: now)
        }
        assert(sample(1, 0) == nil)
        assert(sample(1, 0.2) == nil) // suppress a brief measurement
        let near = sample(1, 0.4)!
        assert(near["distance_band"] as? String == "nearby" && near["should_warn"] as? Bool == true)
        for n in 1...100 { assert(sample(1, 0.4 + Double(n) / 10) == nil) } // no stationary chatter
        assert(sample(0.5, 11) == nil)
        let close = sample(0.5, 11.4)!
        assert(close["distance_band"] as? String == "very_close" && close["should_warn"] as? Bool == true)
        for n in 1...30 { assert(sample(0.61, 11.4 + Double(n) / 10) == nil) } // exit hysteresis
        assert(sample(0.2, 14.5) != nil)
        assert(sample(0.21, 14.6) == nil)
        assert(reporter.currentContext(now: 16)["status"] as? String == "unavailable")
        assert(reporter.currentContext(now: 16)["distance_metres"] == nil)
        assert(reporter.nextEvent(now: 16) == nil)
        let lost = reporter.nextEvent(now: 16.6)!
        assert(lost["status"] as? String == "unavailable" && lost["should_warn"] as? Bool == false)
        assert(sample(0.3, 20, demo: true) == nil)
        let simulated = sample(0.3, 20.4, demo: true)!
        assert(simulated["status"] as? String == "simulation_not_real")
        assert(simulated["distance_metres"] == nil && simulated["should_warn"] as? Bool == false)
        reporter = ProximityReporter()
        assert(sample(1, 30) == nil); _ = sample(1, 30.4)
        let approach = sample(0.7, 33)!
        assert(approach["distance_trend"] as? String == "decreasing")
        assert(approach["should_warn"] as? Bool == false) // warning cooldown
        for invalid: Float in [.nan, .infinity, -.infinity, 0, -1, 9] {
            assert(snapshot(invalid, 40).context(now: 40)["distance_metres"] == nil)
        }
        assert(snapshot(0.5, 40, running: false).context(now: 40)["status"] as? String == "stopped")
        assert(snapshot(0.5, 40).validDistance(now: 39) == nil)
        reporter = ProximityReporter()
        assert(reporter.currentContext(now: 41)["distance_metres"] == nil)
        print("Proximity context checks passed: debounce, hysteresis, cooldown, freshness, trend, invalid data, demo and reset.")
    }
}
