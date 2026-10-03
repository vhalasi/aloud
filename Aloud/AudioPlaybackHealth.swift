import Foundation

/// Uses render-clock progress, not network activity: silence between turns is healthy.
struct AudioPlaybackHealth {
    private var lastSampleTime: Int64?
    private var lastProgress: TimeInterval?
    private var hadPendingAudio = false
    private var lastRecovery: TimeInterval?
    private(set) var recoveryAttempts = 0

    mutating func needsRecovery(now: TimeInterval, engineRunning: Bool,
                                hasPendingAudio: Bool, sampleTime: Int64?) -> Bool {
        if hasPendingAudio {
            if !hadPendingAudio || (sampleTime != nil && sampleTime != lastSampleTime) {
                lastProgress = now
                if let lastRecovery, now - lastRecovery > 5, hadPendingAudio,
                   sampleTime != nil && sampleTime != lastSampleTime { recoveryAttempts = 0 }
            }
        } else { lastProgress = nil }
        hadPendingAudio = hasPendingAudio
        lastSampleTime = sampleTime
        if let lastRecovery, now - lastRecovery < 1 { return false }
        return !engineRunning || (hasPendingAudio && now - (lastProgress ?? now) > 1.5)
    }

    mutating func recovered(now: TimeInterval) {
        recoveryAttempts += 1
        lastRecovery = now
        lastProgress = now
        lastSampleTime = nil
        hadPendingAudio = false
    }

    mutating func interrupted() {
        lastSampleTime = nil
        lastProgress = nil
        hadPendingAudio = false
    }
}
