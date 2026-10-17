# CastDeck — Google TV Remote (iOS)

Native **SwiftUI** remote for Google TV / Android TV. App Store–oriented: local-network pairing, hold-to-talk Gemini/Assistant (PC-mic equivalent = iPhone mic), polished UI.

Not a web wrapper. Uses the official **Android TV Remote Protocol v2** via [AndroidTVRemoteControl](https://github.com/odyshewroman/AndroidTVRemoteControl) (SPM).

## Requirements

- Mac with **Xcode 16+**
- Apple Developer account (for device + App Store)
- iPhone/iPad on the **same Wi‑Fi** as the TV
- Google TV / Chromecast with Google TV

## Open & run

```bash
cd google-tv-remote-ios
open CastDeck.xcodeproj
```

1. Select your Team in **Signing & Capabilities**
2. Run on a physical device (local network discovery needs a real device)
3. Allow **Local Network** + **Microphone** when prompted

## Features

- Bonjour discovery (`_androidtvremote2._tcp`)
- One-time PIN pairing (certs in Keychain)
- Physical-style remote: D-pad, Back, Home, volume, mute, power
- **Hold mic** → `KEYCODE_SEARCH` `START_LONG` + PCM stream → Gemini/Assistant
- Quick-launch YouTube / Netflix / etc.
- Design tokens inspired by shadcn (light surface, clear hierarchy, calm accents)

## App Store checklist

| Item | Status |
|------|--------|
| `NSLocalNetworkUsageDescription` | ✅ Info.plist |
| `NSBonjourServices` (`_androidtvremote2._tcp`) | ✅ |
| `NSMicrophoneUsageDescription` | ✅ (voice / Gemini) |
| Privacy Manifest `PrivacyInfo.xcprivacy` | ✅ |
| No tracking / ATT needed | ✅ local-only |
| Minimum iOS | 17.0 |

### Before submit

1. Replace placeholder app icon in `Assets.xcassets/AppIcon.appiconset`
2. Set unique Bundle ID (default `com.castdeck.googletvremote`)
3. Archive → Distribute App → App Store Connect
4. Privacy Nutrition Labels: Local Network, Microphone — purpose “App Functionality”

## Windows companion

Polished Windows EXE (same protocol):

`..\google-tv-remote-windows\dist\GoogleTVRemote.exe`

## License

MIT
