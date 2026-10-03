# Aloud

An iPhone hackathon prototype for feeling nearby surfaces through haptic pulses.

## Try it

1. Open `Aloud.xcodeproj` in Xcode and select the **Aloud** scheme.
2. For real sensing, select a connected **LiDAR-equipped iPhone**, choose your development team under **Signing & Capabilities**, and run. The bundle identifier is `com.vhalasi.aloud`; change it if your team requires another one.
3. Tap **Start sensing** and allow camera access. Hold the phone upright with the rear camera facing the surface.
4. Begin stationary with a sighted helper moving a large, matte obstacle toward the phone. Pulses should become faster and stronger as the obstacle gets closer. Tap **Stop** to end sensing.

The deployment target is iOS 17.0. Device support is checked with `ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)`. A regular non-LiDAR iPhone and the simulator cannot measure live depth. **Try demo pulses** works without camera access: move the simulated-distance slider left to increase pulse frequency. A physical iPhone is needed to feel vibrations; the simulator only animates the waveform.

## Prototype behavior

- ARKit supplies depth and confidence maps; only the central square of the rear camera view is sampled. No camera images leave the device, and no Google services or API keys are used.
- Medium/high-confidence finite readings are accepted. At least 25% of sampled points (and at least eight readings) must be valid. The 20th percentile favors nearby surfaces while rejecting isolated noisy pixels.
- Measurements update at up to 10 Hz. Closer readings take effect immediately; receding readings are smoothed.
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
```

The standalone checks cover increasing pulse frequency/intensity, distance boundaries, invalid measurements, minimum valid coverage, isolated outliers, and nearby surface selection.

## Validation status

Simulator and unsigned iPhone-device builds passed with Xcode 26.4. On the iPhone 17 / iOS 26.4 simulator, the unsupported-depth state, demo slider (3.0 m to 0.6 m), and Stop behavior were verified. The standalone proximity checks passed. A connected iPhone 15 lacks LiDAR and can only exercise demo haptics. Real LiDAR accuracy, haptic feel, camera authorization, and physical-device interruptions still require device testing. Google voice/vision integration is deferred.
