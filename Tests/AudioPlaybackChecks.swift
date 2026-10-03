import Foundation
@main struct AudioPlaybackChecks {
    static func main() {
        var health = AudioPlaybackHealth()
        assert(!health.needsRecovery(now: 0, engineRunning: true, hasPendingAudio: false, sampleTime: nil))
        assert(!health.needsRecovery(now: 100, engineRunning: true, hasPendingAudio: false, sampleTime: nil))
        assert(health.needsRecovery(now: 101, engineRunning: false, hasPendingAudio: false, sampleTime: nil))
        health.recovered(now: 101)
        assert(!health.needsRecovery(now: 101.5, engineRunning: false, hasPendingAudio: true, sampleTime: nil))
        assert(!health.needsRecovery(now: 102, engineRunning: true, hasPendingAudio: true, sampleTime: 0))
        assert(!health.needsRecovery(now: 103, engineRunning: true, hasPendingAudio: true, sampleTime: 24_000))
        assert(!health.needsRecovery(now: 104, engineRunning: true, hasPendingAudio: true, sampleTime: 24_000))
        assert(health.needsRecovery(now: 105, engineRunning: true, hasPendingAudio: true, sampleTime: 24_000))
        health.recovered(now: 105)
        assert(health.recoveryAttempts == 2)
        health.interrupted()
        assert(!health.needsRecovery(now: 108, engineRunning: true, hasPendingAudio: false, sampleTime: nil))
        assert(!health.needsRecovery(now: 110, engineRunning: true, hasPendingAudio: true, sampleTime: 0))
        assert(!health.needsRecovery(now: 111, engineRunning: true, hasPendingAudio: true, sampleTime: 24_000))
        assert(health.recoveryAttempts == 0)
        assert(!health.needsRecovery(now: 200, engineRunning: true, hasPendingAudio: false, sampleTime: nil))
        assert(!health.needsRecovery(now: 201, engineRunning: true, hasPendingAudio: true, sampleTime: nil))
        assert(health.needsRecovery(now: 203, engineRunning: true, hasPendingAudio: true, sampleTime: nil))
        print("Audio playback checks passed: healthy idle, stopped engine, stalled playback, recovery cooldown, interruption, and sustained recovery")
    }
}
