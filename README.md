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
greets you briefly, then listens for spoken questions and highlights useful visible changes.
The greeting does not mention missing images while the camera starts. **Describe
surroundings** requests another description. You can interrupt by speaking. If voice is silent, press the volume-up button while AI is on and tap **Test speaker** for two tones through the same playback path. **Audio details** shows the output route, volume and completed audio buffers. The latest
question and reply appear as text. **Stop AI** ends network streaming and audio while
local depth/haptics continue; **Stop sensing and AI** ends both. Backgrounding ends both.

- Model: `gemini-3.8-live`, using the Gemini Live v1beta WebSocket API.
- One AVCaptureSession supplies front TrueDepth measurements and unmirrored portrait
  RGB images. JPEG images stream at up to one per second only while AI is connected.
- AVAudioEngine uses video-chat speaker routing, minimal nonvoice ducking, an explicit mixer-to-output connection, 16 kHz mono PCM microphone input and 24 kHz
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

## Nearby places

Google Places API (New) is enabled in the temporary hackathon project
`sthlm-ai26arn-6425` (Stockholm AI-6425). The key named **Aloud iOS Places Hackathon**
is restricted to Places API (New) and the iOS bundle identifier `com.vhalasi.aloud`.
The app sends the corresponding `X-Ios-Bundle-Identifier` header. Set
`PLACES_API_KEY` in the ignored `LocalSecrets.xcconfig` and rebuild; it is embedded
in the app just like the shared Gemini key. No credential values belong in Git.

Start AI asks for **While Using the App** location permission before connecting
the voice session, even without a Places key. Denial leaves voice/vision usable.
Ask **“Where am I?”**, **“Find a restaurant near me”**, **“Is it open?”**, or
**“Are there museums nearby?”**.

- Gemini can call `get_current_location` through the Live WebSocket. This tool
  returns a measured Core Location fix with coordinates, timestamp, age and reported
  accuracy, plus an approximate address from Apple reverse geocoding when available.
  Fixes must be less than 60 seconds old. Approximate permission is supported and
  coarse fixes omit street/house numbers. Address lookup has a four-second deadline;
  its failure does not discard the location. This tool does not require a Places key.
- The prompt directs the agent to try the location tool before claiming it lacks
  location access, qualify approximate fixes and prefer an address over spoken
  coordinates. Permission failures and unavailable fixes have distinct errors.
- With a Places key, Gemini can also call `find_nearby_places` or `get_place_details`.
  The app performs the HTTPS requests and returns the results to Gemini.
- Location requests share the fix with Gemini and send it to Apple for address
  lookup. Nearby searches send the position to Google Places.
- Searches use device coordinates, never coordinates supplied by the model. Fixes
  must be less than 60 seconds old and have reported accuracy within 500 metres.
  There is no background location tracking or persistent location history.
- Nearby Search accepts restaurants, cafes, supermarkets, pharmacies, tourist
  attractions, museums and parks. Radius defaults to 1 km and is bounded to 200 m–3 km;
  it requests up to five results ranked by distance. Distances shown are approximate
  straight-line distances, not walking routes or proof of accessible entrances.
- Place Details accepts only IDs previously retrieved in the current live session.
  It fetches listed opening hours and website data only when requested. Missing
  hours are unknown. Nearby search alone does not identify a building in the image.
- Places results and source links appear under Google Maps attribution. Results
  stay in memory and are cleared when AI stops. Search failures return explicit
  errors to the agent; cancelled tool calls and stopped sessions discard results.
- Tool calls are serialized with at most four pending requests, so a location
  request and a nearby search can complete in sequence. Searches have finite
  timeouts and request explicit field masks. Opening-hours details use a higher Places billing tier than the
  basic nearby search. This integration does not add general web/history research.

On October 3, 2026, the restricted key passed real Nearby Search and Place Details
requests at public Stockholm Central test coordinates. A Gemini Live test invoked
`find_nearby_places`, received real Places results and generated a PCM spoken reply.
The explicit location tool also passed a real Gemini Live round-trip using a
synthetic location fixture: “Where am I?” triggered `get_current_location` and
a spoken response after the tool result. With no camera images sent, session
startup produced a friendly spoken greeting without mentioning missing images.
Signed iPhone and simulator builds, protocol checks, and location freshness/accuracy
checks pass. Actual phone location accuracy and recommendations still need a
physical phone trial.

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

For the Core Location fixture checks, compile for a booted iOS simulator (replace
`<SIMULATOR_ID>` with its identifier):

```sh
xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios17.0-simulator \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  Aloud/PlacesLocation.swift Tests/LocationChecks.swift -o build/location-checks
xcrun simctl spawn <SIMULATOR_ID> "$PWD/build/location-checks"
```

Location checks cover expired/future/invalid fixes, precise versus coarse acceptance,
and accuracy/freshness in the tool payload, without requesting real location access.
The standalone checks cover a non-silent demo starting distance, increasing pulse frequency/intensity, distance boundaries, invalid measurements, minimum valid coverage, isolated outliers, and nearby surface selection.

## Validation status

On October 3, 2026, the TrueDepth/Core Haptics update passed signed iPhone and simulator builds with Xcode 26.4 and was installed and launched on the connected iPhone 15. The user confirmed that both changing TrueDepth distances and physical vibration work well. Simulator checks verified the unsupported-haptics message, the demo starting at 1.0 m, and stopping when leaving the app. Deterministic distance-filter, pulse-curve, and non-silent demo-default checks pass. This verifies basic operation, not calibrated distance accuracy, outdoor range, or navigation reliability. The new Gemini integration passed signed device and simulator builds, protocol fixture checks, and a real server setup handshake plus a PCM voice response using the configured key. The update is installed on the iPhone 15. On-device simultaneous voice, vision and haptics still require a physical trial.

## Matrix cloud agent API

The [Hono backend](backend/README.md) runs unattended Codex jobs on Matrix through
a Cloudflare Worker. The voice agent now uses it for deeper web research.

Start AI and ask **“Look up the history of Stockholm City Hall”** or **“Research
this museum’s official accessibility information.”** Name the place if its identity
is uncertain. Aloud acknowledges the request, researches in the background, and
speaks a short summary with source attribution when finished. You can keep talking
while it works. Ask **“How is the research going?”** or **“Cancel that research”**;
there is also a **Cancel research** button and an expandable result/source view.

- `research_surroundings` is a non-blocking Gemini Live tool. The app submits an
  authenticated Matrix job and polls it independently of Places, camera and audio.
  `get_research_status` and `cancel_research` provide voice controls. Results use
  `WHEN_IDLE` scheduling so they wait for the current response to finish.
- The app includes a fresh Core Location fix only when the question needs it.
  Its accuracy and timestamp travel with it; a location snapshot cannot identify
  a building or provide real-time navigation. Camera frames and microphone audio
  continue going to Gemini and are not streamed to Matrix.
- The Matrix task receives the question and optional location through Cloudflare;
  Codex/OpenAI and browser sources process the research. Job data persists on Matrix
  under the backend's job directories. The app keeps results only for the live session.
- Research from the app is read-only: it does not book, buy, change accounts or send
  messages. Local depth and haptics remain independent of research results.
- There is one research task per app session. Retries reuse an idempotency key.
  Remote execution is capped at five minutes; app polling has a six-minute limit.
  Stopping AI, backgrounding, or tool cancellation drops stale responses and requests
  remote cancellation. Cancellation is best effort when the network/app is unavailable;
  the server deadline still applies. Stop cannot undo completed actions.

For development, put `MATRIX_API_TOKEN` in ignored `LocalSecrets.xcconfig` using
`API_TOKEN` from `backend/.secrets.json`. `MATRIX_API_URL` defaults to the deployed
Worker in `Config.xcconfig`; its `https:/$()/` spelling preserves the double slash
in xcconfig. Neither users nor the voice model enter or receive the credential.
Like the Gemini key, this shared full-access backend token is extractable from a
private hackathon build. A distributed app needs per-user authentication and a
restricted research endpoint. Matrix credential renewal is described in the
backend README; it does not require rebuilding the app unless the API token changes.

Validation on October 3, 2026: signed device and simulator builds passed, along
with protocol/client fixtures for retry identity, authentication failures, a single
active job, cancellation, deadlines and stale sessions. A real Gemini Live session
invoked research, the exact Swift app service called the deployed Matrix API,
and Gemini answered a second question during research before speaking the sourced
result (406,562 PCM bytes). Physical microphone/camera/haptics still require an
on-device check; simulator tests cannot establish those behaviors.

```sh
swiftc Aloud/MatrixResearchService.swift Tests/MatrixResearchChecks.swift -o /tmp/aloud-research-checks
/tmp/aloud-research-checks
swiftc Aloud/LiveProtocol.swift Tests/LiveProtocolChecks.swift -o /tmp/aloud-live-checks
/tmp/aloud-live-checks
```

An opt-in real-network check is also provided in `Tests/MatrixResearchLiveCheck.swift`;
its header shows how to invoke it with the ignored backend credential file.
