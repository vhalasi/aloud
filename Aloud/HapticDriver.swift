import CoreHaptics
import Foundation

/// Owned and used on the main queue. All engine callbacks hop back to it.
final class HapticDriver {
    var onStatus: ((String) -> Void)?
    private var engine: CHHapticEngine?
    private var engineStarted = false

    @discardableResult
    func pulse(intensity: Double, duration: Double = 0.08) -> Bool {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            onStatus?("Haptics unavailable on this device. The simulator cannot vibrate.")
            return false
        }
        do {
            if engine == nil {
                let engine = try CHHapticEngine()
                engine.playsHapticsOnly = true
                engine.isAutoShutdownEnabled = false
                engine.stoppedHandler = { [weak self, weak engine] reason in
                    DispatchQueue.main.async {
                        guard let self, let engine, self.engine === engine else { return }
                        self.engineStarted = false
                        self.onStatus?("Haptics paused (\(reason.rawValue)). Next pulse will retry.")
                    }
                }
                engine.resetHandler = { [weak self, weak engine] in
                    DispatchQueue.main.async {
                        guard let self, let engine, self.engine === engine else { return }
                        self.engineStarted = false
                    }
                }
                self.engine = engine
            }
            guard let engine else { return false }
            if !engineStarted {
                try engine.start()
                engineStarted = true
            }
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(intensity)),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                ],
                relativeTime: 0,
                duration: duration
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            onStatus?("Haptics ready")
            return true
        } catch {
            engineStarted = false
            onStatus?("Vibration could not play: \(error.localizedDescription)")
            return false
        }
    }

    func stop() {
        // Discard this engine so a late stop/reset callback cannot affect a new one.
        engine?.stoppedHandler = { _ in }
        engine?.resetHandler = {}
        engine?.stop(completionHandler: nil)
        engine = nil
        engineStarted = false
    }
}
