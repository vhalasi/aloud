import SwiftUI

struct ContentView: View {
    @StateObject private var monitor = ProximityMonitor()
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
                    Button("Stop", systemImage: "stop.fill") { monitor.stop() }
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

                if monitor.needsSettings {
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { monitor.applicationBecameActive() }
            // Permission prompts temporarily make the app inactive. Stop an active
            // session then, but allow the first permission request to complete.
            if phase == .background || (phase == .inactive && monitor.isRunning) {
                monitor.stop()
            }
        }
        .onDisappear { monitor.stop() }
    }
}

#Preview {
    ContentView()
}
