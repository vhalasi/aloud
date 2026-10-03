import AVFoundation
import os

/// Lifecycle and playback run on main. The input tap owns its converter.
final class LiveAudio {
    var onStatus: ((String) -> Void)?
    var onPlaybackLevel: ((Double, Bool) -> Void)?
    var onFailure: (() -> Void)?
    private struct PendingBuffer {
        let id = UUID()
        let buffer: AVAudioPCMBuffer
    }
    private var pendingBuffers: [PendingBuffer] = []
    private var inputHandler: ((Data) -> Void)?
    private var health = AudioPlaybackHealth()
    private struct OutputSample {
        var level: Double = 0
        var time: TimeInterval = 0
        var generation = UUID()
    }
    private let outputSample = OSAllocatedUnfairLock(initialState: OutputSample())
    private var meterTimer: DispatchSourceTimer?
    private var hasOutputTap = false
    private var meterGeneration = UUID()
    private var smoothedLevel = 0.0
    private var lastVoiceTime: TimeInterval = -.infinity
    private var watchdog: DispatchSourceTimer?
    private var configurationObserver: NSObjectProtocol?
    private var recoveryCount = 0
    private var interruptionCount = 0
    private var isRecovering = false
    private var lastStatusTime: TimeInterval = 0
    private let logger = Logger(subsystem: "com.vhalasi.aloud", category: "VoicePlayback")
    private var completedBuffers = 0
    private var receivedFrames: AVAudioFrameCount = 0
    private var volumeObservation: NSKeyValueObservation?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var hasTap = false
    private var queuedFrames: AVAudioFrameCount = 0
    private var playbackGeneration = UUID()
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    func start(onPCM: @escaping (Data) -> Void) throws {
        stop()
        inputHandler = onPCM
        receivedFrames = 0
        completedBuffers = 0
        recoveryCount = 0
        interruptionCount = 0
        health = AudioPlaybackHealth()
        do {
            try configureSession()
            try buildGraph()
        } catch { stop(); throw error }
        let session = AVAudioSession.sharedInstance()
        volumeObservation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.reportStatus(force: true) }
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.checkPlayback() }
        watchdog = timer
        timer.resume()
        let meter = DispatchSource.makeTimerSource(queue: .main)
        meter.schedule(deadline: .now(), repeating: 0.05)
        meter.setEventHandler { [weak self] in self?.reportPlaybackLevel() }
        meterTimer = meter
        meter.resume()
        reportStatus(force: true)
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord || session.mode != .videoChat ||
            !session.categoryOptions.contains(.defaultToSpeaker) || !session.categoryOptions.contains(.allowBluetoothHFP) {
            try session.setCategory(.playAndRecord, mode: .videoChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        }
        // Recording normally suppresses haptics. Keep proximity feedback enabled.
        try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
    }

    private func buildGraph(using existingEngine: AVAudioEngine? = nil) throws {
        guard let onPCM = inputHandler else { throw AudioError.unavailable }
        let session = AVAudioSession.sharedInstance()
        let engine = existingEngine ?? AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        if !input.isVoiceProcessingEnabled { try input.setVoiceProcessingEnabled(true) }
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        // Voice processing can change the route when it initializes. Prefer the
        // loudspeaker for the handheld prototype, while preserving headphones.
        if session.currentRoute.outputs.contains(where: { $0.portType == .builtInReceiver }) {
            try session.overrideOutputAudioPort(.speaker)
        }
        let sourceFormat = input.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: sourceFormat, to: target) else { throw AudioError.unavailable }
        let player = AVAudioPlayerNode()
        self.player = player
        engine.attach(player)
        player.volume = 1
        let mixer = engine.mainMixerNode
        mixer.outputVolume = 1
        engine.connect(player, to: mixer, format: playbackFormat)
        // Meter samples rendered by the player, not chunks arriving ahead of playback.
        let sampleStore = outputSample
        meterGeneration = UUID()
        let renderGeneration = meterGeneration
        player.installTap(onBus: 0, bufferSize: 1024, format: playbackFormat) { buffer, _ in
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var energy: Float = 0
            for index in 0..<Int(buffer.frameLength) { energy += samples[index] * samples[index] }
            let rms = sqrt(Double(energy) / Double(buffer.frameLength))
            let level = min(1, max(0, rms * 5))
            let now = ProcessInfo.processInfo.systemUptime
            sampleStore.withLock { $0 = OutputSample(level: level, time: now, generation: renderGeneration) }
        }
        hasOutputTap = true
        engine.connect(mixer, to: engine.outputNode, format: engine.outputNode.inputFormat(forBus: 0))
        input.installTap(onBus: 0, bufferSize: 2048, format: sourceFormat) { buffer, _ in
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / sourceFormat.sampleRate)) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            let result = converter.convert(to: output, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard result != .error, error == nil, output.frameLength > 0,
                  let samples = output.int16ChannelData?[0] else { return }
            onPCM(Data(bytes: samples, count: Int(output.frameLength) * 2))
        }
        hasTap = true
        engine.prepare()
        try engine.start()
        player.play()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self, weak engine] _ in
            guard let self, let engine, self.engine === engine else { return }
            // Defer until the hardware has finished changing; the timer also catches
            // stalls that do not send a configuration notification.
            DispatchQueue.main.async { [weak self] in self?.checkPlayback() }
        }
    }

    private func checkPlayback() {
        guard let engine, let player, inputHandler != nil, !isRecovering else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let sampleTime = player.isPlaying ? player.lastRenderTime.flatMap { player.playerTime(forNodeTime: $0)?.sampleTime } : nil
        if health.needsRecovery(now: now, engineRunning: engine.isRunning,
                                hasPendingAudio: !pendingBuffers.isEmpty, sampleTime: sampleTime) {
            do { try recoverPlayback() }
            catch {
                logger.error("Audio graph recovery failed; domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code)")
                #if DEBUG
                print("AUDIO_RECOVERY_ERROR domain=\((error as NSError).domain) code=\((error as NSError).code)")
                #endif
                stop()
                onFailure?()
                return
            }
        }
        reportStatus()
    }

    private func recoverPlayback() throws {
        guard !isRecovering, health.recoveryAttempts < 3 else { throw AudioError.unavailable }
        isRecovering = true
        defer { isRecovering = false }
        health.recovered(now: ProcessInfo.processInfo.systemUptime)
        recoveryCount += 1
        // Keep unplayed buffers, invalidate callbacks from the old graph, and rebuild
        // input conversion/output formats for the current hardware route. Reuse the
        // I/O engine: replacing a live voice-processing I/O unit can invalidate the
        // new unit's route when the old engine is released.
        playbackGeneration = UUID()
        let existingEngine = engine
        tearDownGraph(preservingEngine: true)
        try configureSession()
        try buildGraph(using: existingEngine)
        for entry in pendingBuffers { schedule(entry) }
        logger.info("Rebuilt audio graph; recovery count=\(self.recoveryCount)")
        reportStatus(force: true)
    }

    func play(_ data: Data) throws {
        guard engine != nil, player != nil, !data.isEmpty, data.count.isMultiple(of: 2) else { throw AudioError.unavailable }
        // An audio route/configuration change can stop AVAudioEngine without
        // stopping the WebSocket. Do not silently queue buffers into a stopped engine.
        if engine?.isRunning != true { try recoverPlayback() }
        let count = AVAudioFrameCount(data.count / 2)
        // Bound latency and memory if playback cannot keep up with the network.
        guard queuedFrames + count <= 24_000 * 30 else { throw AudioError.backlog }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: count),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = count
        data.withUnsafeBytes { raw in
            for i in 0..<Int(count) {
                let value = UInt16(raw[i * 2]) | UInt16(raw[i * 2 + 1]) << 8
                samples[i] = Float(Int16(bitPattern: value)) / 32768
            }
        }
        queuedFrames += count
        receivedFrames += count
        let entry = PendingBuffer(buffer: buffer)
        pendingBuffers.append(entry)
        schedule(entry)
        reportStatus()
    }

    private func schedule(_ entry: PendingBuffer) {
        guard let player else { return }
        let generation = playbackGeneration
        player.scheduleBuffer(entry.buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.playbackGeneration == generation,
                      let index = self.pendingBuffers.firstIndex(where: { $0.id == entry.id }) else { return }
                self.pendingBuffers.remove(at: index)
                self.queuedFrames -= min(self.queuedFrames, entry.buffer.frameLength)
                self.completedBuffers += 1
                self.reportStatus()
            }
        }
        if !player.isPlaying { player.play() }
    }

    func testSpeaker() throws {
        // Same PCM decoder, player and audio route as Gemini speech.
        var pcm = Data()
        for index in 0..<16_800 {
            let t = Double(index) / 24_000
            let envelope = min(1, t / 0.02, (0.7 - t) / 0.03)
            let frequency = t < 0.35 ? 523.25 : 659.25
            let sample = Int16(sin(2 * .pi * frequency * t) * max(0, envelope) * 12_000)
            let bits = UInt16(bitPattern: sample)
            pcm.append(UInt8(bits & 255)); pcm.append(UInt8(bits >> 8))
        }
        interrupt(countAsInterruption: false)
        try play(pcm)
    }

    private func reportPlaybackLevel() {
        let now = ProcessInfo.processInfo.systemUptime
        let sample = outputSample.withLock { $0 }
        let rendering = engine?.isRunning == true && player?.isPlaying == true &&
            sample.generation == meterGeneration && now - sample.time < 0.2 && !pendingBuffers.isEmpty
        let target = rendering ? sample.level : 0
        if target > 0.025 { lastVoiceTime = now }
        smoothedLevel += (target - smoothedLevel) * (target > smoothedLevel ? 0.6 : 0.25)
        if smoothedLevel < 0.005 { smoothedLevel = 0 }
        onPlaybackLevel?(smoothedLevel, rendering && now - lastVoiceTime < 0.3)
    }

    private func clearPlaybackLevel() {
        outputSample.withLock { $0.time = 0; $0.level = 0 }
        smoothedLevel = 0
        lastVoiceTime = -.infinity
        onPlaybackLevel?(0, false)
    }

    private func reportStatus(force: Bool = false) {
        guard engine != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastStatusTime >= 0.5 else { return }
        lastStatusTime = now
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute.outputs.map { $0.portType == .builtInSpeaker ? "Speaker" : $0.portName }.joined(separator: ", ")
        let volume = Int((session.outputVolume * 100).rounded())
        let state = engine?.isRunning == true ? "running" : "stopped"
        let queued = String(format: "%.1f", Double(queuedFrames) / 24_000)
        let received = String(format: "%.1f", Double(receivedFrames) / 24_000)
        let details = "\(route.isEmpty ? "No output" : route) · volume \(volume)% · engine \(state) · \(received)s received · \(queued)s queued · \(completedBuffers) buffers played · \(interruptionCount) speech interruptions · \(recoveryCount) audio recoveries"
        onStatus?(details)
        logger.info("Voice engine \(state, privacy: .public); frames received=\(self.receivedFrames); buffers played=\(self.completedBuffers); volume=\(volume); route=\(route, privacy: .public)")
    }

    func interrupt(countAsInterruption: Bool = true) {
        if countAsInterruption { interruptionCount += 1 }
        health.interrupted()
        pendingBuffers.removeAll()
        playbackGeneration = UUID()
        queuedFrames = 0
        clearPlaybackLevel()
        player?.stop()
        if engine?.isRunning == true { player?.play() }
        reportStatus(force: true)
    }

    private func tearDownGraph(preservingEngine: Bool = false) {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if hasTap { engine?.inputNode.removeTap(onBus: 0) }
        hasTap = false
        if hasOutputTap { player?.removeTap(onBus: 0) }
        hasOutputTap = false
        meterGeneration = UUID()
        player?.stop()
        engine?.stop()
        if let player { engine?.detach(player) }
        player = nil
        if preservingEngine { engine?.reset() } else { engine = nil }
    }

    func stop() {
        watchdog?.cancel(); watchdog = nil
        meterTimer?.cancel(); meterTimer = nil
        clearPlaybackLevel()
        volumeObservation = nil
        inputHandler = nil
        playbackGeneration = UUID()
        pendingBuffers.removeAll()
        queuedFrames = 0
        tearDownGraph()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private enum AudioError: Error { case unavailable, backlog }
}
