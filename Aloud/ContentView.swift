import SwiftUI

struct ContentView: View {
    @StateObject private var monitor = ProximityMonitor()
    @StateObject private var live = GeminiLiveClient()
    @Environment(\.scenePhase) private var scenePhase

    private var signal: ProximitySignal? {
        monitor.distance.flatMap { ProximitySignal.at(distance: $0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Aloud")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 12) {
                    Text("See with Aloud").font(.title2.bold())
                    Text(live.status).font(.callout)
                    if live.isActive {
                        Button("Stop AI", systemImage: "mic.slash.fill") { live.stop() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Start AI", systemImage: "mic.fill") { live.start() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!live.hasKey || !monitor.usesTrueDepth)
                    }
                    if !live.hasKey {
                        Text("The developer needs to add the API key and rebuild this app.")
                            .font(.footnote)
                    }
                    if live.isConnected {
                        Button("Describe surroundings", systemImage: "eye") { live.describe() }
                            .buttonStyle(.bordered)
                            .disabled(live.framesSent == 0)
                        Button("Test speaker", systemImage: "speaker.wave.2.fill") { live.testSpeaker() }
                            .buttonStyle(.bordered)
                        Text("Use the volume buttons while AI is on to adjust voice volume.")
                            .font(.footnote).foregroundStyle(.secondary)
                        DisclosureGroup("Audio details") {
                            Text(live.audioStatus).font(.caption)
                        }
                        Text("Front-camera images sent: \(live.framesSent)").font(.caption)
                    }
                    if live.isActive || !live.placesStatus.isEmpty {
                        Text(live.placesStatus.isEmpty ? "Ask where you are or what is nearby." : live.placesStatus)
                            .font(.footnote)
                        Text("Location requests share your position with Gemini and use Apple to look up an address. Nearby searches send your position to Google Places.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !live.nearbyPlaces.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Google Maps").font(.system(size: 14)).fixedSize(horizontal: true, vertical: false)
                            ForEach(live.nearbyPlaces) { place in
                                VStack(alignment: .leading, spacing: 4) {
                                    if let url = place.mapsURL {
                                        Link(place.name, destination: url)
                                    } else { Text(place.name).bold() }
                                    Text("About \(place.metres) m in a straight line").font(.caption)
                                    Text(place.address).font(.caption)
                                    ForEach(place.attributions, id: \.self) { Text($0).font(.caption2) }
                                }
                            }
                        }
                    }
                    if live.hasResearch && live.isActive {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Web research").font(.headline).accessibilityAddTraits(.isHeader)
                            Text(live.researchStatus.isEmpty ? "Ask about a building’s history or ask me to look something up." : live.researchStatus)
                                .font(.callout)
                            if live.isResearching {
                                Button("Cancel research", systemImage: "stop.circle") { live.cancelResearch() }
                                    .buttonStyle(.bordered)
                            }
                            if !live.researchResult.isEmpty {
                                DisclosureGroup("Research details and sources") {
                                    Text(live.researchResult).font(.callout).textSelection(.enabled)
                                }
                            }
                            Text("Research sends your question, and your location when needed, through Matrix to OpenAI. You can keep talking while it works.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if !live.heard.isEmpty {
                        Text("You: \(live.heard)").font(.callout).foregroundStyle(.secondary)
                    }
                    if !live.transcript.isEmpty {
                        Text(live.transcript).font(.body).textSelection(.enabled)
                    }
                    Text("While AI is on, microphone audio and front-camera images are sent to Google Gemini. Hold the phone upright, screen facing what you want described.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .controlSize(.large)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))

                Text("Feel what’s ahead.")
                    .font(.title2.weight(.semibold))
                Text(monitor.cameraInstruction)
                Text("Pulses get faster and stronger as a surface gets closer.")

                VStack(spacing: 16) {
                    Image(systemName: "waveform")
                        .font(.system(size: 44, weight: .semibold))
                        .symbolEffect(.bounce, value: monitor.pulseCount)
                        .accessibilityHidden(true)
                    Text(monitor.distance.map { String(format: "%.1f m", $0) } ?? "—")
                        .font(.system(.largeTitle, design: .rounded).bold())
                        .monospacedDigit()
                        .accessibilityLabel(monitor.isDemo ? "Simulated distance" : "Surface distance")
                        .accessibilityValue(monitor.distance.map { String(format: "%.1f metres", $0) } ?? "Unavailable")
                    Text(signal == nil ? "No proximity pulses" : "Closer means faster pulses")
                        .font(.headline)
                    Text(monitor.message)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 24))

                Button("Test vibration", systemImage: "waveform.path") { monitor.testVibration() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Text(monitor.hapticStatus)
                    .font(.callout)
                Text("If you feel nothing, check Settings → Accessibility → Touch → Vibration.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if monitor.isDemo {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Demo distance — no camera measurement")
                            .font(.headline)
                        Slider(value: $monitor.demoDistance, in: 0.3...3, step: 0.1)
                            .accessibilityLabel("Demo distance")
                            .accessibilityValue(String(format: "%.1f metres", monitor.demoDistance))
                        Text("Move left for closer, faster pulses. The simulator shows pulses but cannot vibrate.")
                            .font(.callout)
                    }
                }

                if monitor.isRunning {
                    Button("Stop sensing and AI", systemImage: "stop.fill") { live.stop(); monitor.stop() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                } else {
                    Button("Start sensing", systemImage: "sensor.fill") { monitor.start() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!monitor.supportsDepth)
                    Button("Try demo pulses", systemImage: "hand.tap") { monitor.startDemo() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }

                if monitor.needsSettings || live.needsSettings {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }

                Text("Prototype: senses only the centre of the camera view. Silence does not mean the path is clear. Test while stationary with a sighted helper; do not rely on this for navigation.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--audio-recovery-check") {
                live.runAudioRecoveryCheck()
            }
            #endif
            live.onReadyForCamera = {
                if !monitor.isRunning || monitor.isDemo { monitor.start() }
            }
            live.onStreamingChanged = { streaming in
                if streaming {
                    monitor.setVideoHandler { [weak live] jpeg in
                        Task { @MainActor in live?.sendFrame(jpeg) }
                    }
                } else {
                    monitor.setVideoHandler(nil)
                }
            }
        }
        .onChange(of: monitor.isRunning) { _, running in
            if !running && live.isConnected { live.stop(message: "Camera stopped. Tap Start AI to reconnect.") }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { monitor.applicationBecameActive() }
            // Permission prompts temporarily make the app inactive. Stop an active
            // session then, but allow the first permission request to complete.
            if phase == .background || (phase == .inactive && monitor.isRunning) {
                if phase == .background || live.isConnected { live.stop() }
                monitor.stop()
            }
        }
        .onDisappear { live.stop(); monitor.stop() }
    }
}

#Preview {
    ContentView()
}
