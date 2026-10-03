import AVFoundation

/// Lifecycle and playback run on main. The input tap owns its converter.
final class LiveAudio {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var hasTap = false
    private var queuedFrames: AVAudioFrameCount = 0
    private var playbackGeneration = UUID()
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    func start(onPCM: @escaping (Data) -> Void) throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        // Recording normally suppresses haptics. Keep proximity feedback enabled.
        try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        let sourceFormat = input.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: sourceFormat, to: target) else { throw AudioError.unavailable }
        let player = AVAudioPlayerNode()
        self.player = player
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
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
    }

    func play(_ data: Data) throws {
        guard let player, data.count.isMultiple(of: 2) else { return }
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
        let generation = playbackGeneration
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.playbackGeneration == generation else { return }
                self.queuedFrames -= min(self.queuedFrames, count)
            }
        }
        if !player.isPlaying { player.play() }
    }

    func interrupt() {
        playbackGeneration = UUID()
        queuedFrames = 0
        player?.stop()
        if engine?.isRunning == true { player?.play() }
    }

    func stop() {
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
