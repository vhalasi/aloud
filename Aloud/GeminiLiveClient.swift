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

    @Published private(set) var placesStatus = ""
    @Published private(set) var nearbyPlaces: [NearbyPlace] = []
    @Published private(set) var researchStatus = ""
    @Published private(set) var researchResult = ""
    @Published private(set) var isResearching = false
    private let research = MatrixResearchService()
    private var researchTask: Task<Void, Never>?
    private var researchCallID: String?
    var hasResearch: Bool { research.isConfigured }
    private let places = PlacesService()
    private var toolTasks: [String: Task<Void, Never>] = [:]
    private var toolQueueTail: Task<Void, Never>?
    private var handledToolIDs = Set<String>()
    var hasPlacesKey: Bool { places.isConfigured }

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
    private var startupTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var pending: [String] = []
    private var observers: [NSObjectProtocol] = []
    private var cameraWatchdog: Task<Void, Never>?
    private var lastCameraFrame: TimeInterval = 0
    private var newOutputTurn = true
    private var newInputTurn = true

    init() {
        research.onUpdate = { [weak self] update in
            self?.researchStatus = update.status
            self?.researchResult = update.result
            self?.isResearching = update.isRunning
        }
        places.onResults = { [weak self] results in self?.nearbyPlaces = results }
        audio.onFailure = { [weak self] in
            self?.stop(message: "Speaker could not recover. Tap Start AI to restart voice.")
        }
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

    #if DEBUG
    func runAudioRecoveryCheck() {
        guard !isActive else { return }
        Task { @MainActor in
            status = "Checking speaker recovery…"
            let passed = await audio.runRecoveryCheck()
            status = passed ? "Speaker recovery check passed" : "Speaker recovery check failed"
            print("ALOUD_AUDIO_RECOVERY_CHECK \(passed ? "PASS" : "FAIL")")
        }
    }
    #endif

    func start() {
        guard !isActive else { return }
        guard hasKey else { status = "Build needs GEMINI_API_KEY in LocalSecrets.xcconfig."; return }
        guard TrueDepthCapture.isSupported else { status = "Live AI needs the front TrueDepth camera on this prototype."; return }
        isActive = true
        needsSettings = false
        status = "Requesting camera and microphone…"
        let token = UUID()
        generation = token
        startupTask = Task {
            let camera = await AVCaptureDevice.requestAccess(for: .video)
            guard generation == token, isActive else { return }
            let microphone = camera ? await AVCaptureDevice.requestAccess(for: .audio) : false
            guard generation == token, isActive else { return }
            guard camera && microphone else {
                stop(message: "Allow camera and microphone in Settings to use AI.")
                needsSettings = true
                return
            }
            do {
                status = "Preparing location access…"
                do {
                    _ = try await places.location.current(requestPermission: true, allowApproximate: true)
                    placesStatus = "Location ready. Ask where you are or what is nearby."
                } catch {
                    guard generation == token, isActive else { return }
                    placesStatus = (error as? PlacesLocation.LocationError)?.localizedDescription ?? "Location unavailable. Ask again to retry."
                    needsSettings = (error as? PlacesLocation.LocationError)?.code == "permission_denied"
                }
                guard generation == token, isActive else { return }
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
        newInputTurn = true
        newOutputTurn = true
        socket.resume()
        enqueue(LiveProtocol.setup(placesEnabled: places.isConfigured, researchEnabled: research.isConfigured))
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
        for id in event.cancelledToolIDs {
            toolTasks.removeValue(forKey: id)?.cancel()
            if researchCallID == id {
                researchTask?.cancel(); researchTask = nil; researchCallID = nil
                research.reset()
            }
        }
        for call in event.toolCalls {
            guard !handledToolIDs.contains(call.id) else { continue }
            handledToolIDs.insert(call.id)
            if ["research_surroundings", "run_matrix_task", "get_research_status", "cancel_research"].contains(call.name) {
                handleResearch(call, token: token)
                continue
            }
            guard toolTasks.count < 4 else {
                enqueue(LiveProtocol.toolResponse(call, result: ["error": "Too many pending requests. Retry after the current requests complete."]))
                continue
            }
            let previous = toolQueueTail
            placesStatus = call.name == "get_current_location" ? "Getting your current location…" : "Looking up Google Maps…"
            let task = Task { [weak self] in
                await previous?.value
                guard !Task.isCancelled, let self, self.generation == token, self.isConnected else { return }
                let result = await self.places.execute(name: call.name, arguments: call.arguments)
                guard !Task.isCancelled, self.generation == token, self.isConnected else { return }
                self.toolTasks[call.id] = nil
                if self.toolTasks.isEmpty { self.toolQueueTail = nil }
                self.placesStatus = result["error"] as? String ?? (call.name == "get_current_location" ? "Current location shared with the voice agent" : "Google Maps results updated")
                if result["error_code"] as? String == "permission_denied" || result["error_code"] as? String == "precise_location_needed" { self.needsSettings = true }
                self.enqueue(LiveProtocol.toolResponse(call, result: result))
            }
            toolTasks[call.id] = task
            toolQueueTail = task
        }
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
            enqueue(LiveProtocol.greet())
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

    private func handleResearch(_ call: LiveProtocol.ToolCall, token: UUID) {
        guard research.isConfigured else {
            enqueue(LiveProtocol.toolResponse(call, result: ["error": "Research is not configured."]))
            return
        }
        if call.name == "get_research_status" {
            var result = research.statusResult()
            result["is_running"] = isResearching
            result["status"] = researchStatus
            enqueue(LiveProtocol.toolResponse(call, result: result, scheduling: "WHEN_IDLE"))
            return
        }
        if call.name == "cancel_research" {
            let running = researchTask != nil
            cancelResearch()
            enqueue(LiveProtocol.toolResponse(call, result: ["status": running ? "Cancellation requested. Wait for confirmation; it may already have finished." : "No research is running."], scheduling: "WHEN_IDLE"))
            return
        }
        guard researchTask == nil else {
            enqueue(LiveProtocol.toolResponse(call, result: ["error": "Research is already running. Use get_research_status or cancel_research."], scheduling: "WHEN_IDLE"))
            return
        }
        researchCallID = call.id
        researchResult = ""
        researchStatus = "Preparing research…"
        isResearching = true
        researchTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.performResearch(call.arguments, provider: call.name == "run_matrix_task" ? .matrix : .browserUse)
            guard self.generation == token, self.isConnected, self.researchCallID == call.id else { return }
            self.researchTask = nil
            self.researchCallID = nil
            self.isResearching = false
            if let error = result["error"] as? String { self.researchStatus = error }
            self.enqueue(LiveProtocol.toolResponse(call, result: result, scheduling: "WHEN_IDLE"))
        }
    }

    private func performResearch(_ arguments: [String: Any], provider: MatrixResearchService.Provider) async -> [String: Any] {
        guard let question = arguments["question"] as? String,
              let includeLocation = arguments["include_location"] as? Bool else {
            return ["error": "Provide a question and include_location boolean."]
        }
        var location: [String: Any]?
        if includeLocation {
            researchStatus = "Getting your location for research…"
            let fix = await places.execute(name: "get_current_location", arguments: [:])
            if Task.isCancelled { return ["error": "Research cancelled before submission."] }
            if fix["error"] != nil { return fix }
            location = fix
        }
        if Task.isCancelled { return ["error": "Research cancelled before submission."] }
        return await research.research(question: question, location: location, provider: provider)
    }

    func cancelResearch() {
        if !research.cancel() { researchTask?.cancel() }
    }

    func sendFrame(_ jpeg: Data) {
        guard isConnected else { return }
        lastCameraFrame = ProcessInfo.processInfo.systemUptime
        guard pending.count < 10 else { return }
        enqueue(LiveProtocol.media(jpeg, mimeType: "image/jpeg", kind: "video"))
        framesSent += 1
    }

    func testSpeaker() {
        guard isConnected else { return }
        do { try audio.testSpeaker() }
        catch { audioStatus = "Speaker test failed. Stop AI and start it again." }
    }

    func describe() {
        guard isConnected, framesSent > 0 else { return }
        audio.interrupt(countAsInterruption: false)
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
        startupTask?.cancel(); startupTask = nil
        for task in toolTasks.values { task.cancel() }
        toolTasks.removeAll()
        toolQueueTail = nil
        handledToolIDs.removeAll()
        researchTask?.cancel(); researchTask = nil; researchCallID = nil
        research.reset()
        researchStatus = ""
        researchResult = ""
        isResearching = false
        places.reset()
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
