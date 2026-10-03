# Aloud

An iPhone hackathon prototype with local proximity haptics and a Gemini Live voice companion using the front camera.

## Try it

1. Open `Aloud.xcodeproj` in Xcode and select the **Aloud** scheme.
2. Select a connected **iPhone with a front TrueDepth camera** (including iPhone 15), choose your development team under **Signing & Capabilities**, and run. The bundle identifier is `com.vhalasi.aloud`; change it if your team requires another one.
3. Tap the single **Start** button and allow microphone/camera access. It starts voice and proximity sensing together. Point the **front camera at the surface, screen facing away from you**. Keep fingers clear of the Dynamic Island / notch. Start with a nearby object around 30–80 cm away; usable range must be tested, not assumed.
4. The voice orb follows rendered playback amplitude. The proximity meter fills and changes from mint to amber/coral as something gets closer, alongside the local vibrations. Missing depth is labelled unavailable, never clear.
5. The top-right **…** opens session details, conversation text, research sources, Google Maps results, and optional speaker/vibration tests. **End session** stops voice, sensing and haptics together. There are no startup test tones.

The deployment target is iOS 17.0. The live experience requires front TrueDepth;
the rear LiDAR sensing implementation remains in the project. The simulator has
neither live depth nor physical haptics. Debug-only `--ui-preview idle`, `listening`,
`speaking`, `near`, and `connecting` fixtures render labelled visual previews without
starting microphone, camera, network or haptics. They do not simulate real measurements.

## Voice interface

The main screen has one Start/End action and a quiet details button. A layered
mint/blue orb deforms with a smoothed RMS meter from rendered player samples,
not incoming network chunks. The meter is sampled at 20 Hz and clears on stop,
interruption or stalled rendering. Idle/Reduce Motion views do not continuously
animate. The camera-centred proximity display includes metres, a text state and
an increasing warm glow; meaning is not conveyed by color alone.

Controls have VoiceOver labels and at least 48-point targets. Text scales with
Dynamic Type, long layouts scroll, and Reduce Motion disables continuous orb
motion and proximity pulses. Inactive/error sessions stop both subsystems. Opening
session details does not stop an active session.

On 2026-10-03, idle/speaking/nearby layouts and accessibility-sized text were inspected
in the simulator. Signed iPhone and simulator builds passed. The connected iPhone
passed induced playback recovery and metering checks before the launch-triggered
test was removed; the final app was installed and launched normally.

## Live voice and front-camera vision

Speech-start detection uses Gemini's `START_SENSITIVITY_LOW` setting to reduce
accidental turns and interruptions in busy surroundings. It does not identify the
user's voice or guarantee rejection of nearby conversations. Speech-end timing
and intentional spoken interruptions retain their default behavior.

The developer supplies one shared hackathon key; users do not enter credentials.
Copy `LocalSecrets.xcconfig.example` to `LocalSecrets.xcconfig`, paste the Gemini API key
on the `GEMINI_API_KEY =` line, save, and rebuild. This local file is ignored by Git.
`Config.xcconfig` injects it into the compiled app's Info.plist. The embedded key is
extractable from the app; this is for private hackathon testing. A distributed app
should obtain short-lived Live API tokens from a backend instead.

Tap **Start**, allow microphone/camera access, and hold the phone upright with its
**front camera / screen facing the scene**. Aloud starts depth sensing if necessary,
greets you briefly, then listens for spoken questions and highlights useful visible changes.
The greeting does not mention missing images while the camera starts. In session
details, **Describe surroundings** requests another description. You can interrupt by speaking. If voice is silent, press the volume-up button while AI is on and tap **Test speaker** for two tones through the same playback path. **Session details → Diagnostics** shows the output route, volume, engine state, seconds of audio
received and queued, completed buffers, server speech interruptions and automatic
recovery count. A half-second watchdog detects stopped engines and stalled render
clocks, rebuilds playback on the existing voice-processing engine, and reschedules
unplayed audio. Silence between turns is not a playback failure. Recovery is bounded;
persistent failures ask you to restart AI. Interrupted speech is discarded and never
replayed by recovery. These counters distinguish missing incoming speech from queued
speech that is not advancing; they cannot prove that sound was physically audible. The latest
question and reply appear in session details. **End session**, backgrounding, or
a failed voice session stops both AI and proximity sensing.

- Model: `gemini-3.8-live`, using the Gemini Live v1beta WebSocket API.
- One AVCaptureSession supplies front TrueDepth measurements and unmirrored portrait
  RGB images. JPEG images stream at up to one per second only while AI is connected.
- AVAudioEngine uses video-chat speaker routing, minimal nonvoice ducking, an explicit mixer-to-output connection, 16 kHz mono PCM microphone input and 24 kHz
  playback. Audio recording explicitly permits haptics. There are no separate STT/TTS services.
- The app waits for setup acknowledgement, bounds outgoing/audio playback queues,
  clears playback on interruption and stops the session if camera images stop arriving.
  Local depth/haptics never wait for network/model responses.
- Context compression is enabled. When the service closes a connection or announces
  its connection limit, tap Start to open a fresh session (no automatic resumption).
- Microphone audio, camera images and summarized proximity readings go to Google while AI is active. They are not
  written to local files. Transcripts are held in memory. Error messages omit credentials.

References: [model](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-live),
[Live protocol](https://ai.google.dev/api/live).

## Proximity context and visual cautions

The live agent receives camera-centred surface-distance events and can call
`get_proximity_status` for a fresh reading. Events include source, measurement time,
age, approximate metres, distance trend, and whether a brief warning is appropriate.
Local vibration remains independent of cloud connectivity, speech and model decisions.
A changing distance does not establish the user's walking direction or identify an object.

Prototype voice bands are **nearby below 1.2 m** and **very close below 0.6 m**.
Transitions must persist for 300 ms, use wider exit thresholds to suppress boundary
jitter, and are sent at most once every two seconds. Most repeated warnings have an
eight-second cooldown; entering the very-close band can request another warning.
Updates wait until the greeting/current model response finishes and the send queue
is uncongested. They are supplementary context, not immediate collision alarms.
Stale readings expire after 600 ms. Simulation/stopped/unavailable states contain
no real distance, and missing depth never means a path is clear.

The prompt asks for concise cautions about visible obstacles, curbs and crossings.
At crossings it prioritizes a clearly identified **pedestrian** signal for that
crossing, describes WALK/don't-walk and meaningful changes, and distinguishes vehicle
traffic lights. Unclear or old signal images must not be guessed. It never declares
crossing safe or tells someone to cross based on a light, absent visible traffic,
or depth. The camera cannot establish all traffic conditions. This remains a
prototype for awareness; real-world pedestrian-signal recognition is unvalidated.

Validation on 2026-10-03: signed device build and protocol/depth checks passed; update
installed and launched on iPhone 15. In a real Gemini Live session, a supplied 0.5 m
sensor event elicited “There is a surface very close to the camera” with PCM audio.
The same session declined to treat a vehicle's green light as permission to cross.
This verifies message/voice behavior, not real-world obstacle or traffic accuracy.

```sh
swiftc Aloud/ProximitySignal.swift Tests/ProximityContextChecks.swift -o /tmp/aloud-context-checks
/tmp/aloud-context-checks
```

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

- TrueDepth uses `AVCaptureDepthDataOutput` on a serial background queue, with filtering disabled and conversion to Float32 depth in metres. Only frames reporting absolute depth accuracy are accepted. The central square of the front camera view is sampled. Raw depth maps stay on the device. Summarized distance/freshness events and RGB images are sent to Gemini only while AI is on.
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

## Browser Use research and Matrix computer tools

The [Hono backend](backend/README.md) runs unattended Codex jobs on Matrix through
a Cloudflare Worker. Web research uses Browser Use Cloud with Gemini 3.6 Flash
(low reasoning). Matrix and Codex remain available for files, calculations and
other requested cloud computer tasks through `run_matrix_task`.

Start AI and ask **“Look up the history of Stockholm City Hall”** or **“Research
this museum’s official accessibility information.”** Name the place if its identity
is uncertain. Aloud acknowledges the request, researches in the background, and
speaks a short summary with source attribution when finished. You can keep talking
while it works. Ask **“How is the research going?”** or **“Cancel that research”**;
there is also a **Cancel research** button and an expandable result/source view.

- `research_surroundings` is a non-blocking Gemini Live tool. The app submits an
  authenticated Browser Use job and polls it independently of Places, camera and audio.
  `get_research_status` and `cancel_research` provide voice controls. Results use
  `WHEN_IDLE` scheduling so they wait for the current response to finish.
- The app includes a fresh Core Location fix only when the question needs it.
  Its accuracy and timestamp travel with it; a location snapshot cannot identify
  a building or provide real-time navigation. Camera frames and microphone audio
  continue going to Gemini Live and are not streamed to Browser Use or Matrix.
- Browser Use receives the question and optional location through Cloudflare;
  Google Gemini and browser sources process the research. Job data persists in
  Cloudflare Durable Objects and Browser Use history. Matrix tasks instead use
  Matrix/Codex and persist in its job directories. The app keeps results only for the live session.
- Research from the app is read-only: it does not book, buy, change accounts or send
  messages. Local depth and haptics remain independent of research results.
- There is one research task per app session. Retries reuse an idempotency key.
  Browser Use runs have a $0.25 provider cost cap and a five-minute server deadline; app polling has a six-minute limit.
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
invoked Browser Use research through the exact Swift app service,
and Gemini answered a second question during research before speaking the sourced
result (391,200 PCM bytes). A simple IANA lookup took 13.3 seconds at the provider
and cost $0.021786; a repeat took 47.1 seconds end to end, so latency varies. The signed update was
installed and launched on the connected iPhone 15. Physical microphone/camera/haptics still require an
on-device check; simulator tests cannot establish those behaviors.

```sh
swiftc Aloud/MatrixResearchService.swift Tests/MatrixResearchChecks.swift -o /tmp/aloud-research-checks
/tmp/aloud-research-checks
swiftc Aloud/LiveProtocol.swift Tests/LiveProtocolChecks.swift -o /tmp/aloud-live-checks
/tmp/aloud-live-checks
```

An opt-in real-network check is also provided in `Tests/MatrixResearchLiveCheck.swift`;
its header shows how to invoke it with the ignored backend credential file.


## Audio recovery validation

On October 3, 2026, the connected iPhone passed a debug-only recovery check that
paused the audio engine with audio pending, paused the player with audio pending,
and then interrupted queued audio. Both stalls recovered and reported played buffers;
the interrupted queue stayed empty. This validates induced playback faults, not the
exact cause of every reported intermittent silent period. Signed iPhone and simulator
builds and the playback-health/protocol checks passed.

```sh
swiftc Aloud/AudioPlaybackHealth.swift Tests/AudioPlaybackChecks.swift -o /tmp/aloud-audio-checks
/tmp/aloud-audio-checks
```

The launch-triggered recovery check and its test tones have been removed. Normal
startup opens the idle screen. Quiet automatic recovery remains enabled during
voice sessions; **Test speaker** is available only when explicitly tapped in details.
