# CastDeck — Chromecast with Google TV remote for iOS

CastDeck is an independent, native SwiftUI remote app. The first tab is the remote; the second tab has settings, logging, and compatibility information.

## Supported receivers

- **Chromecast with Google TV, Google TV Streamer, and Android TV devices that expose Android TV Remote v2:** remote directional buttons and pairing via TLS TCP/6466 and TCP/6467.
- **Original cast-only Chromecast receivers:** discovered through `_googlecast._tcp` and identified as cast-only. They **do not** implement Android TV Remote v2; this build does not control them. Do not mistake cast discovery for support for screen mirroring or media casting.
- Media casting, screen mirroring, installed-app enumeration, and iPhone microphone PCM streaming are **not implemented**. The search key triggers the TV search interface; it does not stream microphone audio from the phone.

## Build and install

```sh
brew install xcodegen
xcodegen generate --spec project.yml
xcodebuild -project CastDeck.xcodeproj -scheme CastDeck -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
```

GitHub Actions publishes an **unsigned IPA**. Sign it for your own device using a permitted signing method. The app requires iOS 17 or newer.

## How connection works

1. iPhone and TV must be reachable on the same local network. Allow Local Network access.
2. Open **Choose a TV** and scan or enter the TV's IP address manually.
3. The client creates an RSA key pair and a self-signed X.509 certificate on first use. The private key remains in the device Keychain.
4. Connect via Android TV Remote v2. If not paired, start pairing over TCP 6467, enter the **six-character hexadecimal PIN** displayed on the TV, and wait for the TV's confirmation.
5. A connection counts as successful only after the TV's Remote v2 handshake finishes. Commands are sent using `KeyPress`; shortcuts use supported `DeepLink` messages.

If pairing is revoked on the TV, reconnect and pair again. The TV's certificate is not pinned by the upstream library; use a trusted local network.

## Settings

Haptic feedback, automatic discovery, system/light/dark appearance, reconnect/disconnect, plain-text diagnostics sharing, and compatibility details. The remote includes a TV keyboard for A–Z, 0–9 and spaces using Android key events.

## Development

- The protocol dependency is [odyshewroman/AndroidTVRemoteControl](https://github.com/odyshewroman/AndroidTVRemoteControl).
- The former demonstration client and disabled bridge were removed: no fake success states, no discarded key commands.
- Device verification is needed on an actual Google TV; simulator compilation and a UI screenshot do not prove pairing or control.
- Local Network permission is required. No microphone permission is requested because the app does not record microphone audio.
- App icon needs a branded 1024x1024 image before App Store distribution.

## License

MIT. Independent application; not affiliated with Google.
