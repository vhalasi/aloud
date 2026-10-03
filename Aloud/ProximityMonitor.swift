import ARKit
import AVFoundation
import Combine
import UIKit

/// UI, delegate callbacks, and the pulse timer all run on the main queue.
final class ProximityMonitor: NSObject, ObservableObject, ARSessionDelegate {
    @Published private(set) var isRunning = false
    @Published private(set) var isDemo = false
    @Published private(set) var distance: Float?
    @Published private(set) var message = "Ready to start"
    @Published private(set) var needsSettings = false
    @Published private(set) var pulseCount = 0
    @Published var demoDistance: Double = 3 {
        didSet {
            if isDemo { distance = Float(demoDistance) }
        }
    }

    let supportsDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    private let session = ARSession()
    private let feedback = UIImpactFeedbackGenerator(style: .heavy)
    private var timer: Timer?
    private var lastPulse: TimeInterval = 0
    private var lastReading: TimeInterval = 0
    private var lastFrame: TimeInterval = 0
    private var startRequest = UUID()
    private var startWhenActive = false
    private var depthWasUnavailable = false

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = .main
        if !supportsDepth { message = "Live depth needs an iPhone with LiDAR." }
    }

    func start() {
        guard supportsDepth else { return }
        stop()
        needsSettings = false
        let request = UUID()
        startRequest = request
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            message = "Allow camera access to measure distance."
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.startRequest == request else { return }
                    if granted {
                        self.startWhenActive = true
                        self.applicationBecameActive()
                    } else if !granted {
                        self.cameraDenied()
                    }
                }
            }
        default:
            cameraDenied()
        }
    }

    func startDemo() {
        stop()
        needsSettings = false
        isDemo = true
        isRunning = true
        distance = Float(demoDistance)
        message = "Demo — simulated distance"
        beginPulses()
    }

    func stop() {
        startRequest = UUID()
        startWhenActive = false
        session.pause()
        timer?.invalidate()
        timer = nil
        isRunning = false
        isDemo = false
        distance = nil
        lastPulse = 0
        lastReading = 0
        lastFrame = 0
        depthWasUnavailable = false
        UIApplication.shared.isIdleTimerDisabled = false
        message = supportsDepth ? "Stopped" : "Live depth needs an iPhone with LiDAR."
    }

    func applicationBecameActive() {
        guard startWhenActive, UIApplication.shared.applicationState == .active else { return }
        startWhenActive = false
        startSession()
    }

    private func cameraDenied() {
        needsSettings = true
        message = "Camera access is required. Enable it in Settings."
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func startSession() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics = .sceneDepth
        isRunning = true
        lastReading = ProcessInfo.processInfo.systemUptime
        message = "Looking for a reliable depth reading…"
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        beginPulses()
    }

    private func beginPulses() {
        UIApplication.shared.isIdleTimerDisabled = true
        feedback.prepare()
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard isRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !isDemo && now - lastReading > 0.6 {
            distance = nil
            message = "Depth unavailable. Hold the rear camera forward."
            if !depthWasUnavailable {
                UIAccessibility.post(notification: .announcement, argument: message)
                depthWasUnavailable = true
            }
        }
        guard let distance, let signal = ProximitySignal.at(distance: distance) else {
            lastPulse = 0
            return
        }
        if now - lastPulse >= signal.interval {
            feedback.impactOccurred(intensity: CGFloat(signal.intensity))
            feedback.prepare()
            lastPulse = now
            pulseCount += 1
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isRunning, !isDemo, frame.timestamp - lastFrame >= 0.1 else { return }
        lastFrame = frame.timestamp
        guard case .normal = frame.camera.trackingState,
              let depth = frame.sceneDepth,
              let measurement = readCentralDepth(depth) else {
            // Stop immediately on invalid data; the timer announces prolonged loss.
            distance = nil
            if !depthWasUnavailable { message = "Waiting for reliable depth…" }
            return
        }
        // Respond immediately to closer surfaces; damp jitter when moving away.
        distance = distance.map { min(measurement, $0 * 0.7 + measurement * 0.3) } ?? measurement
        lastReading = ProcessInfo.processInfo.systemUptime
        depthWasUnavailable = false
        message = "Measuring the centre of the camera view"
    }

    private func readCentralDepth(_ depth: ARDepthData) -> Float? {
        guard let confidence = depth.confidenceMap else { return nil }
        let map = depth.depthMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        CVPixelBufferLockBaseAddress(confidence, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(confidence, .readOnly)
            CVPixelBufferUnlockBaseAddress(map, .readOnly)
        }
        guard let depthBase = CVPixelBufferGetBaseAddress(map),
              let confidenceBase = CVPixelBufferGetBaseAddress(confidence) else { return nil }
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        guard CVPixelBufferGetWidth(confidence) == width,
              CVPixelBufferGetHeight(confidence) == height else { return nil }
        let depthStride = CVPixelBufferGetBytesPerRow(map)
        let confidenceStride = CVPixelBufferGetBytesPerRow(confidence)
        var samples: [Float] = []
        var count = 0
        // A centred square remains centred in both portrait and landscape.
        let halfSide = min(width, height) / 6
        for y in stride(from: height / 2 - halfSide, to: height / 2 + halfSide, by: 2) {
            let depths = depthBase.advanced(by: y * depthStride).assumingMemoryBound(to: Float32.self)
            let confidences = confidenceBase.advanced(by: y * confidenceStride).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: width / 2 - halfSide, to: width / 2 + halfSide, by: 2) {
                count += 1
                if confidences[x] >= ARConfidenceLevel.medium.rawValue {
                    samples.append(depths[x])
                }
            }
        }
        return DepthEstimate.metres(samples: samples, totalCount: count)
    }

    func sessionWasInterrupted(_ session: ARSession) {
        guard isRunning, !isDemo else { return }
        stop()
        message = "Camera interrupted. Tap Start to try again."
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        guard isRunning, !isDemo else { return }
        stop()
        message = "Camera session failed. Tap Start to try again."
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}
