# Wire AndroidTVRemoteControl in Xcode (Mac)

The UI and session layer are ready. Finish the protocol bridge on a Mac:

1. `brew install xcodegen` then `xcodegen generate` in this folder  
   **or** File → New → App in Xcode and add the `App/` + `Sources/` folders
2. File → Add Package Dependencies →  
   `https://github.com/odyshewroman/AndroidTVRemoteControl`
3. Open `Sources/Services/AndroidTVClient.swift` and align `#if canImport(AndroidTVRemoteControl)` calls with the package’s current `PairingManager` / `RemoteManager` API (names drift slightly by version)
4. Confirm voice: after `SEARCH` + `START_LONG`, use the package’s voice/PCM hooks if present; otherwise stream via whatever `RemoteVoicePayload` helper the package exposes
5. Drop a 1024×1024 App Icon into `AppIcon.appiconset`
6. Signing → your Team → run on a **physical iPhone** (Local Network won’t work in Simulator the same way)

## App Store

- Archive on Mac
- Privacy labels: Local Network + Microphone = App Functionality
- No tracking / no ATT
