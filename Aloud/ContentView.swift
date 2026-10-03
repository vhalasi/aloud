import SwiftUI

private enum AloudStyle {
    static let background = Color(red: 0.035, green: 0.065, blue: 0.07)
    static let surface = Color(red: 0.075, green: 0.11, blue: 0.12)
    static let ink = Color(red: 0.95, green: 0.96, blue: 0.91)
    static let muted = Color(red: 0.63, green: 0.71, blue: 0.69)
    static let mint = Color(red: 0.70, green: 0.96, blue: 0.82)
    static let amber = Color(red: 1, green: 0.75, blue: 0.39)
    static let coral = Color(red: 1, green: 0.49, blue: 0.37)
}

struct ContentView: View {
    @StateObject private var monitor = ProximityMonitor()
    @StateObject private var live = GeminiLiveClient()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showingDetails = false
    @AppStorage("necklaceMode") private var necklaceMode = true

    // Debug-only visual fixtures never start a camera, microphone, network session or haptic.
    private var previewMode: String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--ui-preview"), args.count > index + 1 { return args[index + 1] }
        #endif
        return nil
    }
    private var active: Bool { previewMode.map { $0 != "idle" } ?? live.isActive }
    private var inverted: Bool { necklaceMode && active }
    private var connected: Bool { previewMode.map { $0 != "idle" && $0 != "connecting" } ?? live.isConnected }
    private var speaking: Bool { previewMode.map { $0 == "speaking" || $0 == "near" } ?? live.isSpeaking }
    private var level: Double { previewMode == nil ? live.outputLevel : speaking ? 0.65 : 0 }
    private var distance: Float? { previewMode == "near" ? 0.5 : previewMode == "speaking" ? 1.4 : previewMode == "listening" ? 2.1 : monitor.distance }
    private var proximity: Double { distance.map { max(0, min(1, (2.5 - Double($0)) / 2.1)) } ?? 0 }
    private var voiceTitle: String { !active ? "Your surroundings,\nspoken." : !connected ? "Getting ready…" : speaking ? "Aloud is speaking" : "I’m listening" }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    header
                    Spacer(minLength: 24)
                    VStack(spacing: 14) {
                        Text(!active ? "A LITTLE MORE INDEPENDENCE" : !connected ? "CONNECTING" : speaking ? "HERE WITH YOU" : "VOICE & AWARENESS")
                            .font(.system(.caption2, design: .monospaced).weight(.medium))
                            .tracking(2.4)
                            .foregroundStyle(AloudStyle.muted)
                        Text(voiceTitle)
                            .font(.system(active ? .title : .largeTitle, design: .serif).weight(.medium))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(AloudStyle.ink)
                            .contentTransition(.opacity)
                            .accessibilityAddTraits(.isHeader)
                    }
                    .padding(.top, 12)

                    VoiceOrb(active: active, speaking: speaking, level: level, reduceMotion: reduceMotion)
                        .frame(height: typeSize.isAccessibilitySize ? 200 : min(geometry.size.height * 0.39, 330))
                        .accessibilityHidden(true)

                    if active {
                        ProximityVisual(distance: connected ? distance : nil, active: connected,
                                        pulseCount: monitor.pulseCount, reduceMotion: reduceMotion)
                            .padding(.bottom, 18)
                        if live.isResearching {
                            Label("Looking that up. You can keep talking.", systemImage: "sparkle.magnifyingglass")
                                .font(.footnote).foregroundStyle(AloudStyle.muted)
                                .multilineTextAlignment(.center).padding(.bottom, 10)
                        }
                    } else {
                        Text("Listen to the world around you.\nFeel what’s getting closer.")
                            .font(.body).foregroundStyle(AloudStyle.muted)
                            .multilineTextAlignment(.center).lineSpacing(4)
                            .padding(.bottom, 24)
                    }
                    Spacer(minLength: 12)
                    controls
                }
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 18)
                .frame(minHeight: geometry.size.height)
            }
        }
        .background {
            ZStack {
                AloudStyle.background
                RadialGradient(colors: [AloudStyle.mint.opacity(active ? 0.055 : 0.035), .clear],
                               center: .center, startRadius: 0, endRadius: 340)
                if active && proximity > 0 {
                    LinearGradient(colors: [.clear, AloudStyle.coral.opacity(proximity * 0.12)], startPoint: .center, endPoint: .bottom)
                }
            }.ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: active)
        // Rotate within the safe area: controls remain clear of the camera cutout
        // and home indicator, including on phones without upside-down autorotation.
        .rotationEffect(.degrees(inverted ? 180 : 0))
        .background(AloudStyle.background.ignoresSafeArea())
        .sheet(isPresented: $showingDetails) {
            details
                .rotationEffect(.degrees(inverted ? 180 : 0))
                .presentationDragIndicator(.hidden)
        }
        .onAppear(perform: configureSession)
        .onChange(of: necklaceMode) { _, enabled in monitor.setNecklaceMode(enabled) }
        .onChange(of: live.isActive) { previous, current in
            // One session: failure, interruption and Stop return both subsystems to idle.
            if previous && !current { monitor.stop() }
        }
        .onChange(of: monitor.isRunning) { _, running in
            if !running && live.isConnected { live.stop(message: "Camera stopped. Tap Start to reconnect.") }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { monitor.applicationBecameActive() }
            if phase == .background || (phase == .inactive && monitor.isRunning) {
                if phase == .background || live.isConnected { live.stop() }
                monitor.stop()
            }
        }
        .onDisappear { stopSession() }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 9) {
                Image(systemName: "waveform").font(.system(size: 21, weight: .medium)).foregroundStyle(AloudStyle.mint)
                Text("aloud").font(.system(size: 29, weight: .semibold, design: .rounded)).tracking(-1)
            }.accessibilityElement(children: .ignore).accessibilityLabel("Aloud")
            Spacer()
            if previewMode != nil { Text("PREVIEW").font(.caption2).foregroundStyle(AloudStyle.muted) }
            Button { showingDetails = true } label: {
                Image(systemName: "ellipsis").font(.system(size: 21, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(.white.opacity(0.055), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.08)))
            }
            .foregroundStyle(AloudStyle.ink)
            .accessibilityLabel("Session details and settings")
        }.foregroundStyle(AloudStyle.ink)
    }

    private var controls: some View {
        VStack(spacing: 16) {
            if !active && live.status != "AI is off" {
                Text(live.status).font(.callout).foregroundStyle(AloudStyle.amber)
                    .multilineTextAlignment(.center)
            }
            if active && !connected {
                Text(live.status).font(.callout).foregroundStyle(AloudStyle.muted).multilineTextAlignment(.center)
            }
            Button {
                guard previewMode == nil else { return }
                if active { stopSession() } else { live.start() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: active ? "stop.fill" : "waveform")
                        .font(.system(size: active ? 16 : 22, weight: .semibold))
                    Text(active ? connected ? "End session" : "Cancel" : "Start")
                        .font(.system(.headline, design: .rounded))
                }
                .frame(maxWidth: .infinity).frame(minHeight: 66)
                .background(active ? AloudStyle.surface : AloudStyle.mint, in: Capsule())
                .overlay(Capsule().strokeBorder(active ? Color.white.opacity(0.15) : .clear))
                .foregroundStyle(active ? AloudStyle.ink : AloudStyle.background)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(active ? "Stop AI and proximity sensing" : "Start AI and proximity sensing")
            .accessibilityHint(active ? "Ends the microphone, camera and vibration session." : "Starts the voice assistant, front camera and proximity vibrations.")
            Text(active ? "Front camera facing forward · You can interrupt" : "Voice + proximity, together")
                .font(.footnote).foregroundStyle(AloudStyle.muted).multilineTextAlignment(.center)
        }
    }

    private var details: some View {
        NavigationStack {
            List {
                Section("Conversation") {
                    if live.heard.isEmpty && live.transcript.isEmpty { Text("Your conversation will appear here.").foregroundStyle(.secondary) }
                    if !live.heard.isEmpty { Text("You: \(live.heard)").foregroundStyle(.secondary).textSelection(.enabled) }
                    if !live.transcript.isEmpty { Text(live.transcript).textSelection(.enabled) }
                    if live.isConnected {
                        Button("Describe surroundings", systemImage: "eye") { live.describe() }.disabled(live.framesSent == 0)
                    }
                }
                if live.isResearching || !live.researchStatus.isEmpty || !live.researchResult.isEmpty {
                    Section("Web research") {
                        Text(live.researchStatus)
                        if live.isResearching { Button("Cancel research", role: .destructive) { live.cancelResearch() } }
                        if !live.researchResult.isEmpty { Text(live.researchResult).textSelection(.enabled) }
                    }
                }
                if !live.nearbyPlaces.isEmpty {
                    Section("Google Maps") {
                        ForEach(live.nearbyPlaces) { place in
                            VStack(alignment: .leading, spacing: 6) {
                                if let url = place.mapsURL { Link(place.name, destination: url) } else { Text(place.name).bold() }
                                Text("About \(place.metres) m in a straight line").font(.caption)
                                Text(place.address).font(.caption)
                                ForEach(place.attributions, id: \.self) { Text($0).font(.caption2) }
                            }
                        }
                    }
                }
                Section("Camera & feedback") {
                    Toggle("Necklace mode", isOn: $necklaceMode)
                        .accessibilityHint("Rotates the live interface and camera images for wearing the phone upside down. The idle screen stays upright.")
                    Text("The screen flips after Start and returns upright when the session ends. Wear the phone with its charging port at the top. Turn off Necklace mode for upright handheld use.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(monitor.cameraInstruction)
                    Text(monitor.message)
                    Button("Test vibration", systemImage: "waveform.path") { monitor.testVibration() }
                    Text(monitor.hapticStatus).font(.caption).foregroundStyle(.secondary)
                    if live.isConnected {
                        Button("Test speaker", systemImage: "speaker.wave.2.fill") { live.testSpeaker() }
                        Text("Use the iPhone volume buttons to adjust the voice.").font(.caption)
                    }
                    if monitor.needsSettings || live.needsSettings {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                    DisclosureGroup("Diagnostics") {
                        Text(live.status)
                        Text(live.audioStatus)
                        Text("Front-camera images sent: \(live.framesSent)")
                        Text("Automatic scene reviews: \(live.sceneReviewsSent)")
                        if !live.placesStatus.isEmpty { Text(live.placesStatus) }
                    }.font(.caption)
                }
                Section("About this prototype") {
                    Text("Only the centre of the camera view is measured. No reading does not mean a clear path. This is an awareness aid, not a crossing or navigation safety system.")
                    Text("While active, audio, front-camera images and proximity readings go to Google Gemini. Requested location lookups use Apple and Google Places. Web research uses Browser Use and Google; computer tasks use Matrix and OpenAI.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .tint(AloudStyle.mint)
            .navigationTitle("Session details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingDetails = false } } }
        }.preferredColorScheme(.dark)
    }

    private func stopSession() { live.stop(); monitor.stop() }

    private func configureSession() {
        monitor.setNecklaceMode(necklaceMode)
        guard previewMode == nil else { return }
        live.onReadyForCamera = { if !monitor.isRunning || monitor.isDemo { monitor.start() } }
        live.onStreamingChanged = { streaming in
            if streaming {
                monitor.setProximityHandler { [weak live] snapshot in live?.sendProximity(snapshot) }
                monitor.setVideoHandler { [weak live] jpeg in Task { @MainActor in live?.sendFrame(jpeg) } }
            } else {
                monitor.setVideoHandler(nil)
                monitor.setProximityHandler(nil)
            }
        }
    }
}

/// A layered, slowly drifting membrane. Voice energy increases its size and deformation.
private struct VoiceOrb: View {
    let active: Bool
    let speaking: Bool
    let level: Double
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !active)) { timeline in
            let time = reduceMotion || !active ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) * 0.325
                let energy = reduceMotion ? 0 : level
                let outer = CGRect(x: center.x - radius * 1.5, y: center.y - radius * 1.5, width: radius * 3, height: radius * 3)
                context.fill(Path(ellipseIn: outer), with: .radialGradient(
                    Gradient(colors: [AloudStyle.mint.opacity(active ? 0.10 + energy * 0.10 : 0.06), .clear]),
                    center: center, startRadius: radius * 0.65, endRadius: radius * 1.5))
                let colors: [[Color]] = [
                    [Color(red: 0.25, green: 0.54, blue: 0.66), Color(red: 0.08, green: 0.21, blue: 0.33)],
                    [Color(red: 0.44, green: 0.77, blue: 0.79), Color(red: 0.14, green: 0.38, blue: 0.56)],
                    [AloudStyle.mint, Color(red: 0.35, green: 0.64, blue: 0.77)],
                    [Color(red: 0.91, green: 0.99, blue: 0.86), AloudStyle.mint.opacity(0.45)]
                ]
                for layer in 0..<4 {
                    let phase = time * 0.45 + Double(layer) * 1.7
                    let scale = 1.08 - Double(layer) * 0.075 + energy * 0.12
                    let offset = CGPoint(x: center.x + CGFloat(sin(phase * 0.7) * Double(layer) * 3),
                                         y: center.y - CGFloat(layer) * radius * 0.035)
                    let path = membrane(center: offset, radius: radius * scale, phase: phase,
                                        amplitude: active ? 0.035 + energy * 0.10 : 0.025)
                    context.fill(path, with: .linearGradient(Gradient(colors: colors[layer]),
                        startPoint: CGPoint(x: center.x - radius, y: center.y - radius),
                        endPoint: CGPoint(x: center.x + radius * 0.8, y: center.y + radius)))
                    context.stroke(path, with: .color(.white.opacity(0.13)), lineWidth: 0.7)
                }
                let sheen = CGRect(x: center.x - radius * 0.58, y: center.y - radius * 0.78,
                                   width: radius * 1.16, height: radius * 0.85)
                context.fill(Path(ellipseIn: sheen), with: .radialGradient(
                    Gradient(colors: [.white.opacity(0.3), .clear]),
                    center: CGPoint(x: center.x - radius * 0.2, y: center.y - radius * 0.35),
                    startRadius: 0, endRadius: radius * 0.68))
            }
        }
    }

    private func membrane(center: CGPoint, radius: Double, phase: Double, amplitude: Double) -> Path {
        Path { path in
            for index in 0...160 {
                let angle = Double(index) / 160 * 2 * Double.pi
                let wave = sin(angle * 3 + phase) * 0.55 + sin(angle * 5 - phase * 0.7) * 0.3 + cos(angle * 2 + phase * 0.6) * 0.15
                let r = radius * (1 + wave * amplitude)
                let point = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        }
    }
}

private struct ProximityVisual: View {
    let distance: Float?
    let active: Bool
    let pulseCount: Int
    let reduceMotion: Bool
    @State private var glow = 0.0
    private var closeness: Double { distance.map { max(0, min(1, (2.5 - Double($0)) / 2.1)) } ?? 0 }
    private var color: Color { distance == nil ? AloudStyle.muted : distance! < 0.6 ? AloudStyle.coral : distance! < 1.2 ? AloudStyle.amber : AloudStyle.mint }
    private var title: String { !active ? "Preparing proximity" : distance == nil ? "Depth unavailable" : distance! < 0.6 ? "Very close" : distance! < 1.2 ? "Something nearby" : "Sensing ahead" }

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 8) {
                    Image(systemName: distance == nil ? "viewfinder" : "sensor.fill").font(.caption)
                    Text(title).font(.subheadline.weight(.medium))
                }
                Spacer(minLength: 8)
                Text(distance.map { String(format: "%.1f m", $0) } ?? "—")
                    .font(.system(.title3, design: .rounded).weight(.medium)).monospacedDigit()
            }.foregroundStyle(color)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.09))
                    if distance != nil {
                        Capsule().fill(LinearGradient(colors: [color.opacity(0.35), color], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(10, geometry.size.width * closeness))
                            .shadow(color: color.opacity(0.5), radius: reduceMotion ? 0 : 6 + (glow * 7))
                    }
                }
            }.frame(height: 7)
            Text(distance == nil ? "No reading doesn’t mean a clear path." : "Camera-centred distance · Closer means stronger pulses")
                .font(.caption).foregroundStyle(AloudStyle.muted)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .background(color.opacity(0.035 + closeness * 0.045), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(color.opacity(0.14 + closeness * 0.2), lineWidth: 1))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: closeness)
        .task(id: pulseCount) {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.06)) { glow = 1 }
            do { try await Task.sleep(for: .milliseconds(70)) } catch { return }
            withAnimation(.easeOut(duration: 0.2)) { glow = 0 }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(distance.map { String(format: "Surface approximately %.1f metres from the camera", $0) } ?? "Distance unavailable. This does not mean the path is clear.")
    }
}

#Preview { ContentView() }
