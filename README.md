# Aloud

An iPhone hackathon app exploring realtime voice and vision assistance for blind people.

## Current scope

This is a native SwiftUI starter app with an accessible welcome screen, Dynamic Type support, and light/dark appearance. Google model integration, camera capture, and microphone streaming have not been implemented yet. No API keys or external dependencies are required to launch it.

## Run

1. Open `Aloud.xcodeproj` in Xcode.
2. Select the **Aloud** scheme and an iPhone simulator.
3. Press **Run** (Command-R).

The deployment target is iOS 17.0. For a physical iPhone, select your development team under **Signing & Capabilities** and change the bundle identifier if necessary. The starter identifier is `com.vhalasi.aloud`.

## Command-line build

```sh
xcodebuild -project Aloud.xcodeproj -scheme Aloud \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

Camera and microphone permission descriptions should be added when those features are implemented. Keep service credentials out of source control.

## Startup verification

On October 3, 2026, the Debug build succeeded with Xcode 26.4 (17E192). The app was installed and launched on the iPhone 17 simulator running iOS 26.4 (23E244). The welcome screen was visually verified and the app process remained running. This was a simulator startup smoke check; physical-device and voice/vision functionality testing is still pending.
