import Foundation

@main
struct ProximityChecks {
    static func main() {
        precondition(ProximitySignal.at(distance: Float(ProximitySignal.demoDistance)) != nil, "Demo must start in the active haptic range")
        for invalid: Float in [.nan, .infinity, -.infinity, -1, 0, 2.5, 4] {
            precondition(ProximitySignal.at(distance: invalid) == nil)
        }
        var previousInterval = 1.0
        var previousIntensity = 0.0
        for distance in stride(from: Float(2.49), through: 0.4, by: -0.01) {
            let signal = ProximitySignal.at(distance: distance)!
            precondition(signal.interval <= previousInterval + 0.000001)
            precondition(signal.intensity >= previousIntensity - 0.000001)
            precondition((0.119...0.85).contains(signal.interval))
            precondition((0.35...1.001).contains(signal.intensity))
            previousInterval = signal.interval
            previousIntensity = signal.intensity
        }
        precondition(abs(ProximitySignal.at(distance: 0.2)!.interval - 0.12) < 0.000001)
        precondition(DepthEstimate.metres(samples: [], totalCount: 100) == nil)
        precondition(DepthEstimate.metres(samples: Array(repeating: 1, count: 24), totalCount: 100) == nil)
        precondition(DepthEstimate.metres(samples: Array(repeating: .nan, count: 100), totalCount: 100) == nil)
        let surface = Array(repeating: Float(2), count: 99)
        precondition(DepthEstimate.metres(samples: [0.05] + surface, totalCount: 100) == 2)
        let nearby = Array(repeating: Float(0.5), count: 30) + Array(repeating: Float(3), count: 70)
        precondition(DepthEstimate.metres(samples: nearby, totalCount: 100) == 0.5)
        print("Proximity checks passed: invalid data, coverage, outliers, nearby surfaces, and increasing pulse rate/intensity.")
    }
}
