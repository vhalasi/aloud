# Aloud

An iPhone hackathon prototype with local proximity haptics and a Gemini Live voice companion using the front camera.

## Try it

1. Open `Aloud.xcodeproj` in Xcode and select the **Aloud** scheme.
2. For real sensing, select a connected **iPhone with a front TrueDepth camera** (including iPhone 15) or a LiDAR-equipped iPhone, choose your development team under **Signing & Capabilities**, and run. The bundle identifier is `com.vhalasi.aloud`; change it if your team requires another one.
3. Tap **Start sensing** and allow camera access. With TrueDepth, point the **front camera at the surface, screen facing away from you**. Keep fingers clear of the Dynamic Island / notch. Start with a nearby object around 30–80 cm away; usable range must be tested, not assumed.
4. Tap **Test vibration** for one strong 350 ms pulse. If nothing is felt, check **Settings → Accessibility → Touch → Vibration**. The haptic status reports engine errors or unsupported hardware; successful playback does not prove the user felt it.
5. Begin stationary with a sighted helper moving a large, matte obstacle toward the phone. Pulses should become faster and stronger as the obstacle gets closer. Tap **Stop** to end sensing.

The deployment target is iOS 17.0. TrueDepth is preferred when `AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)` is available. Otherwise the existing rear LiDAR implementation is used when supported. The simulator has neither live depth nor physical haptics. **Try demo pulses** works without camera access and resets to 1 metre so it immediately requests pulses: move the simulated-distance slider left to increase pulse frequency.

## Live voice and front-camera vision

The developer supplies one shared hackathon key; users do not enter credentials.
Copy `LocalSecrets.xcconfig.example` to `LocalSecrets.xcconfig`, paste the Gemini API key
on the `GEMINI_API_KEY =` line, save, and rebuild. This local file is ignored by Git.
`Config.xcconfig` injects it into the compiled app's Info.plist. The embedded key is
extractable from the app; this is for private hackathon testing. A distributed app
should obtain short-lived Live API tokens from a backend instead.

Tap **Start AI**, allow microphone/camera access, and hold the phone upright with its
**front camera / screen facing the scene**. Aloud starts depth sensing if necessary,
briefly describes the first image, then listens for spoken questions. **Describe
surroundings** requests another description. You can interrupt by speaking. The latest
question and reply appear as text. **Stop AI** ends network streaming and audio while
local depth/haptics continue; **Stop sensing and AI** ends both. Backgrounding ends both.

- Model: `gemini-3.8-live`, using the Gemini Live v1beta WebSocket API.
- One AVCaptureSession supplies front TrueDepth measurements and unmirrored portrait
  RGB images. JPEG images stream at up to one per second only while AI is connected.
- AVAudioEngine uses voice processing, 16 kHz mono PCM microphone input and 24 kHz
  playback. Audio recording explicitly permits haptics. There are no separate STT/TTS services.
- The app waits for setup acknowledgement, bounds outgoing/audio playback queues,
  clears playback on interruption and stops AI if camera images stop arriving. Local
  depth/haptics remain independent of network/model errors.
- Context compression is enabled. When the service closes a connection or announces
  its connection limit, tap Start AI to open a fresh session (no automatic resumption).
- Microphone audio and camera images go to Google while AI is active. They are not
  written to local files. Transcripts are held in memory. Error messages omit credentials.

References: [model](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-live),
[Live protocol](https://ai.google.dev/api/live).

## Prototype behavior

- TrueDepth uses `AVCaptureDepthDataOutput` on a serial background queue, with filtering disabled and conversion to Float32 depth in metres. Only frames reporting absolute depth accuracy are accepted. The central square of the front camera view is sampled. Depth data stays on the device. RGB images are sent to Gemini only while AI is on.
- On the LiDAR fallback, ARKit supplies depth and confidence maps from the rear camera. Instructions always identify which camera to point at the obstacle.
- TrueDepth accepts finite, positive samples; unlike the ARKit path, it has no per-pixel confidence map. LiDAR accepts only medium/high-confidence finite readings. At least 25% of sampled points (and at least eight readings) must be valid. The 20th percentile favors nearby surfaces while rejecting isolated noisy pixels.
- Measurements update at up to 10 Hz. Closer readings take effect immediately; receding readings are smoothed.
- Core Haptics generates explicit 80 ms continuous pulses; hardware support and engine failures are surfaced in the UI, and the engine restarts after a reset. The camera session has no microphone input and does not automatically configure the app audio session.
- At 2.5 metres or farther, there are no proximity pulses. Between 2.5 m and 0.4 m, the interval decreases from about 0.85 seconds to 0.12 seconds, and requested intensity increases from 35% to 100%. Closer readings stay at the maximum rate. Actual feel depends on the iPhone.
- Invalid depth/tracking stops proximity pulses immediately. If valid readings stop arriving for 0.6 seconds, the reading is cleared and VoiceOver announces depth unavailability once. Sensing can recover when reliable frames return.
- Stop, backgrounding, session interruptions, and session failures stop sensing and pulses. Returning to the app after a stopped session requires Start again.
- The screen supports Dynamic Type, VoiceOver labels, and a separate, clearly labelled simulated-distance mode.

This is a central-view distance experiment, **not a navigation or collision-avoidance system**. It can miss thin objects, objects outside the centre, glass, reflective surfaces, and drop-offs. Silence never means the path is clear. Do not walk blindfolded or rely on the prototype instead of established mobility aids.

## Build and checks

```sh
xcodebuild -project Aloud.xcodeproj -scheme Aloud \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

mkdir -p build
xcrun swiftc Aloud/ProximitySignal.swift Tests/ProximityChecks.swift \
  -o build/proximity-checks
./build/proximity-checks

xcrun swiftc Aloud/LiveProtocol.swift Tests/LiveProtocolChecks.swift \
  -o build/live-protocol-checks
./build/live-protocol-checks
```

The standalone checks cover a non-silent demo starting distance, increasing pulse frequency/intensity, distance boundaries, invalid measurements, minimum valid coverage, isolated outliers, and nearby surface selection.

## Validation status

On October 3, 2026, the TrueDepth/Core Haptics update passed signed iPhone and simulator builds with Xcode 26.4 and was installed and launched on the connected iPhone 15. The user confirmed that both changing TrueDepth distances and physical vibration work well. Simulator checks verified the unsupported-haptics message, the demo starting at 1.0 m, and stopping when leaving the app. Deterministic distance-filter, pulse-curve, and non-silent demo-default checks pass. This verifies basic operation, not calibrated distance accuracy, outdoor range, or navigation reliability. The new Gemini integration passed signed device and simulator builds, protocol fixture checks, and a real server setup handshake plus a PCM voice response using the configured key. The update is installed on the iPhone 15. On-device simultaneous voice, vision and haptics still require a physical trial.
