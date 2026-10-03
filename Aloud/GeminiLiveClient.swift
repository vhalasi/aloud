import AVFoundation
import Combine
import UIKit

@MainActor
final class GeminiLiveClient: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var isConnected = false
    @Published private(set) var status = "AI is off"
    @Published private(set) var transcript = ""
    @Published private(set) var heard = ""
    @Published private(set) var framesSent = 0
    @Published private(set) var audioStatus = "Start AI to enable voice."
    @Published private(set) var needsSettings = false

    var hasKey: Bool { !Self.apiKey.isEmpty }
    var onReadyForCamera: (() -> Void)?
    var onStreamingChanged: ((Bool) -> Void)?
    private static var apiKey: String {
        let key = (Bundle.main.object(forInfoDictionaryKey: "GeminiAPIKey") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return key.hasPrefix("$(") ? "" : key
    }
    private var socket: URLSessionWebSocketTask?
    private let audio = LiveAudio()
    private var generation = UUID()
    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var pending: [String] = []
    private var observers: [NSObjectProtocol] = []
    private var cameraWatchdog: Task<Void, Never>?
    private var lastCameraFrame: TimeInterval = 0
    private var newOutputTurn = true
    private var newInputTurn = true
    private var initialDescriptionSent = false

    init() {
        audio.onStatus = { [weak self] text in self?.audioStatus = text }
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                if name == AVAudioSession.routeChangeNotification {
                    let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                    // Our own voice-chat setup changes the route too. Only an unplugged
                    // device requires the user to restart the audio graph.
                    guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                }
                if name == AVAudioSession.interruptionNotification {
                    let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                    guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
                }
                Task { @MainActor in
                    guard let self, self.isConnected else { return }
                    self.stop(message: "Audio interrupted or changed. Tap Start AI to reconnect.")
                }
            })
        }
    }

    func start() {
        guard !isActive else { return }
        guard hasKey else { status = "Build needs GEMINI_API_KEY in LocalSecrets.xcconfig."; return }
        guard TrueDepthCapture.isSupported else { status = "Live AI needs the front TrueDepth camera on this prototype."; return }
        isActive = true
        needsSettings = false
        status = "Requesting camera and microphone…"
        let token = UUID()
        generation = token
        Task {
            let camera = await AVCaptureDevice.requestAccess(for: .video)
            guard generation == token, isActive else { return }
            let microphone = camera ? await AVCaptureDevice.requestAccess(for: .audio) : false
            guard generation == token, isActive else { return }
            guard camera && microphone else {
                stop(message: "Allow camera and microphone in Settings to use AI.")
                needsSettings = true
                return
            }
            // Permission sheets briefly deactivate the app. Wait for their dismissal.
            for _ in 0..<30 {
                if UIApplication.shared.applicationState == .active { break }
                try? await Task.sleep(for: .milliseconds(100))
                guard generation == token, isActive else { return }
            }
            guard UIApplication.shared.applicationState == .active else { stop(); return }
            connect(token: token)
        }
    }

    private func connect(token: UUID) {
        var url = URLComponents(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
        url.queryItems = [URLQueryItem(name: "key", value: Self.apiKey)]
        let socket = URLSession.shared.webSocketTask(with: url.url!)
        self.socket = socket
        status = "Connecting to Gemini…"
        transcript = ""
        heard = ""
        framesSent = 0
        initialDescriptionSent = false
        newInputTurn = true
        newOutputTurn = true
        socket.resume()
        enqueue(LiveProtocol.setup())
        receiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self, self.generation == token, self.isActive else { return }
                    let data: Data
                    switch message {
                    case .data(let bytes): data = bytes
                    case .string(let string): data = Data(string.utf8)
                    @unknown default: continue
                    }
                    try self.handle(LiveProtocol.parse(data), token: token)
                }
            } catch {
                guard let self, self.generation == token, self.isActive else { return }
                // Never surface raw URLSession errors: they may contain the credential URL.
                let code = socket.closeCode.rawValue
                self.stop(message: "AI connection ended (\(code)). Check internet, API key and model access, then Start AI again.")
            }
        }
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.generation == token, !self.isConnected else { return }
            self.stop(message: "Gemini did not finish connecting. Check your key and network, then retry.")
        }
    }

    private func handle(_ event: LiveProtocol.Event, token: UUID) throws {
        if let code = event.errorCode {
            stop(message: "Gemini rejected the request (\(code)). Check the API key, quota and model access.")
            return
        }
        if event.goingAway {
            stop(message: "Live session reached its connection limit. Tap Start AI for a new session.")
            return
        }
        if event.ready && !isConnected {
            timeoutTask?.cancel()
            do {
                try audio.start { [weak self] data in
                    Task { @MainActor in
                        guard let self, self.generation == token, self.isConnected else { return }
                        self.enqueue(LiveProtocol.media(data, mimeType: "audio/pcm;rate=16000", kind: "audio"))
                    }
                }
            } catch {
                stop(message: "Could not start microphone/speaker. Check audio permissions and retry.")
                return
            }
            isConnected = true
            status = "Live · front camera + microphone"
            onStreamingChanged?(true)
            onReadyForCamera?()
            lastCameraFrame = ProcessInfo.processInfo.systemUptime
            cameraWatchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, let self, self.generation == token, self.isConnected else { return }
                    if ProcessInfo.processInfo.systemUptime - self.lastCameraFrame > 8 {
                        self.stop(message: "Front-camera images stopped. Tap Start AI to try again.")
                        return
                    }
                }
            }
        }
        if event.interrupted {
            audio.interrupt()
            newOutputTurn = true
        }
        if let text = event.inputText {
            if newInputTurn { heard = ""; newInputTurn = false }
            heard = String((heard + text).suffix(1500))
        }
        if let text = event.outputText {
            if newOutputTurn { transcript = ""; newOutputTurn = false }
            transcript = String((transcript + text).suffix(3000))
        }
        if !event.interrupted {
            do {
                for data in event.audio { try audio.play(data) }
            } catch {
                stop(message: "Voice playback failed. Tap Start AI to restart the speaker.")
                return
            }
        }
        if event.turnComplete { newOutputTurn = true; newInputTurn = true }
    }

    func sendFrame(_ jpeg: Data) {
        guard isConnected else { return }
        lastCameraFrame = ProcessInfo.processInfo.systemUptime
        guard pending.count < 10 else { return }
        enqueue(LiveProtocol.media(jpeg, mimeType: "image/jpeg", kind: "video"))
        framesSent += 1
        if !initialDescriptionSent { initialDescriptionSent = true; describe() }
    }

    func testSpeaker() {
        guard isConnected else { return }
        do { try audio.testSpeaker() }
        catch { audioStatus = "Speaker test failed. Stop AI and start it again." }
    }

    func describe() {
        guard isConnected, framesSent > 0 else { return }
        audio.interrupt()
        newOutputTurn = true
        enqueue(LiveProtocol.describe())
    }

    private func enqueue(_ value: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else { return }
        guard pending.count < 100 else { stop(message: "Network is too slow for live audio. Tap Start AI to retry."); return }
        pending.append(string)
        guard sendTask == nil else { return }
        let token = generation
        sendTask = Task { [weak self] in
            guard let self else { return }
            do {
                while !self.pending.isEmpty, self.generation == token, !Task.isCancelled {
                    let next = self.pending.removeFirst()
                    try await socket.send(.string(next))
                }
                if self.generation == token { self.sendTask = nil }
            } catch {
                guard self.generation == token, self.isActive else { return }
                self.stop(message: "Could not send to Gemini. Check your connection and retry.")
            }
        }
    }

    func stop(message: String = "AI is off") {
        generation = UUID()
        isConnected = false
        isActive = false
        onStreamingChanged?(false)
        receiveTask?.cancel(); receiveTask = nil
        sendTask?.cancel(); sendTask = nil
        timeoutTask?.cancel(); timeoutTask = nil
        cameraWatchdog?.cancel(); cameraWatchdog = nil
        pending.removeAll()
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        audio.stop()
        status = message
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
