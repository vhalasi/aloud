import AVFoundation
import os

/// Lifecycle and playback run on main. The input tap owns its converter.
final class LiveAudio {
    var onStatus: ((String) -> Void)?
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
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .videoChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        // Recording normally suppresses haptics. Keep proximity feedback enabled.
        try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
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
        receivedFrames = 0
        completedBuffers = 0
        volumeObservation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.reportStatus() }
        }
        reportStatus()
    }

    func play(_ data: Data) throws {
        guard let player, let engine, !data.isEmpty, data.count.isMultiple(of: 2) else { throw AudioError.unavailable }
        // An audio route/configuration change can stop AVAudioEngine without
        // stopping the WebSocket. Do not silently queue buffers into a stopped engine.
        if !engine.isRunning { try engine.start() }
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
        let generation = playbackGeneration
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.playbackGeneration == generation else { return }
                self.queuedFrames -= min(self.queuedFrames, count)
                self.completedBuffers += 1
                self.reportStatus()
            }
        }
        if !player.isPlaying { player.play() }
        reportStatus()
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
        interrupt()
        try play(pcm)
    }

    private func reportStatus() {
        guard engine != nil else { return }
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute.outputs.map { $0.portType == .builtInSpeaker ? "Speaker" : $0.portName }.joined(separator: ", ")
        let volume = Int((session.outputVolume * 100).rounded())
        let state = engine?.isRunning == true ? "running" : "stopped"
        let details = "\(route.isEmpty ? "No output" : route) · volume \(volume)% · \(completedBuffers) buffers played"
        onStatus?(details)
        logger.info("Voice engine \(state, privacy: .public); frames received=\(self.receivedFrames); buffers played=\(self.completedBuffers); volume=\(volume); route=\(route, privacy: .public)")
    }

    func interrupt() {
        playbackGeneration = UUID()
        queuedFrames = 0
        player?.stop()
        if engine?.isRunning == true { player?.play() }
    }

    func stop() {
        volumeObservation = nil
        interrupt()
        if hasTap { engine?.inputNode.removeTap(onBus: 0) }
        hasTap = false
        engine?.stop()
        player = nil
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private enum AudioError: Error { case unavailable, backlog }
}
