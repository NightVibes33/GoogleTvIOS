# CastDeck — Chromecast with Google TV remote for iOS

CastDeck is an independent, native SwiftUI remote app. The iPhone screen is the remote, with a TV chooser and a separate settings sheet. Device discovery uses Bonjour and logs actionable errors.

## Supported receivers

- **Chromecast with Google TV, Google TV Streamer, and Android TV devices that expose Android TV Remote v2:** remote directional buttons and pairing via TLS TCP/6466 and TCP/6467.
- **Original cast-only Chromecast receivers:** discovered through `_googlecast._tcp` and identified as cast-only. They **do not** implement Android TV Remote v2; this build does not control them. Do not mistake cast discovery for support for screen mirroring or media casting.
- The iOS 27 Screen Mirror sheet now contains an experimental local full-screen HLS casting pipeline. Installed-app enumeration and iPhone microphone PCM streaming to Assistant are **not implemented**. The search key triggers the TV search interface; it does not stream microphone audio from the phone.

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

Haptic feedback, automatic discovery, D-pad/swipe navigation, reconnect/disconnect, and plain-text diagnostics sharing. The remote includes a TV keyboard for A–Z, 0–9 and spaces using Android key events.

## Development

- The protocol dependency is [odyshewroman/AndroidTVRemoteControl](https://github.com/odyshewroman/AndroidTVRemoteControl).
- The former demonstration client and disabled bridge were removed: no fake success states, no discarded key commands.
- Device verification is needed on an actual Google TV; simulator compilation and a UI screenshot do not prove pairing or control.
- Local Network permission is required. No microphone permission is requested because the app does not record microphone audio.
- App icon needs a branded 1024x1024 image before App Store distribution.


## Bonjour discovery and -72008

The iOS `NSNetServicesMissingRequiredConfigurationError` (`-72008`) means the **installed app** is missing required local-network configuration, irrespective of what's present in a source `Info.plist`. This repository builds with **XcodeGen**, so both `NSLocalNetworkUsageDescription` and `NSBonjourServices` must be defined under `targets.CastDeck.info.properties` in `project.yml`. The CI workflow now opens the **packaged IPA** and asserts both keys are present before publishing an artifact.

When replacing a previously installed build, use the new corrected unsigned IPA (signed as required by your installer). In iPhone Settings, permit Local Network for CastDeck. If the service still isn't found, use the TV's IP and check that the router does not isolate Wi-Fi clients.


## Full iPhone screen mirror (iOS 27)

The remote remains independent from Google Cast. Tap the **screen mirror icon** in its header, choose a Cast receiver (discovered by the official Google Cast sender SDK), select **1080p/H.264** or **4K/HEVC**, then start screen mirroring. The iOS system sharing picker must grant full-display capture.

Pipeline: `SCContentSharingPicker` → `SCStream` screen + device audio sample buffers → Core Image letterboxing + hardware AVAssetWriter H.264/HEVC and stereo AAC → local fMP4 HLS served over HTTP to the Chromecast Default Media Receiver using the official Google Cast iOS Sender SDK. The background capture mode is `screen-capture`. No remote server and no recording upload.

- 1080p outputs 1920×1080 H.264, target 6 Mb/s. 4K outputs 3840×2160 HEVC, target 18 Mb/s, 30 fps. This is **output encoding resolution**, not native capture detail and not a guarantee that the receiver can decode 4K.
- AAC stereo targets 192 kb/s and 48 kHz. Video and audio use the same ScreenCaptureKit presentation timestamps. Output synchronization and actual audible playback **must be measured on a real device**.
- Fragmented HLS uses 2-second segments, so it has inherent latency. No claims of near-zero delay or flawless audio.
- Protected/DRM playback can yield blank video or silent audio. Original 1080p-only Chromecasts cannot decode 4K HEVC; use the 1080p preset there.
- Google Cast SDK discovery is separate from the Android TV Remote v2 pairing. Mirroring does **not** require remote PIN pairing.
- Keep the iPhone and Chromecast on the same reachable Wi-Fi. Screen capture and the embedded HTTP server need to remain active.
- Unverified in physical hardware: Cast receiver playback, HEVC compatibility, encoded audio and sustained quality. CI compilation is not a physical streaming test.

### Open source used

- [ScreenCaptureKit iOS sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios) for OS 27 picker and capture lifecycle.
- [HLSStreamer](https://github.com/jdkula/HLSStreamer) for reference architecture of phone-hosted HLS.
- [GoogleCast SDK binary Swift package](https://github.com/SRGSSR/google-cast-sdk) for the official Cast sender API.


## Device identity, friendly names, and duplicate prevention

Cast-enabled Google TV receivers often announce both `_googlecast._tcp` and
`_androidtvremote2._tcp`. They may have different Bonjour instance names
despite being the **same physical TV**. CastDeck therefore resolves the
advertisements, groups the records by the resolved IPv4 endpoint, and shows
one device row, preferring Android TV Remote v2 capabilities and the Cast
`fn` TXT-record friendly name when available. Unresolved advertisements
do not temporarily create duplicate rows. In Screen Mirror, the official
Google Cast Sender SDK's device ID is used for duplicate elimination and
its `friendlyName` is displayed. Two genuinely distinct IP addresses or
Cast SDK device IDs remain separate; do not merge TVs merely because they
share the same display name.

This discovery strategy was implemented and built for testing, but not yet
verified on multiple physical Chromecast receivers.


## Consumer UI and Files app logging (v1.4)

The first screen is a full-page TV remote. First-time users are shown the
friendly TV picker; returning users can reconnect automatically to their last
paired TV without navigating technical menus. Device discovery presents one
row per physical Chromecast/Google TV. Connection diagnostics, manual
network addresses, codec information and troubleshooting are behind Help
disclosure sections rather than cluttering the remote.

The app creates real, rotating text logs in its **Documents/Logs** directory
when it starts. They are visible at **Files → Browse → On My iPhone →
CastDeck → Logs** because both `UIFileSharingEnabled` and
`LSSupportsOpeningDocumentsInPlace` are enabled in XcodeGen's generated
`Info.plist`. Files include app, remote pairing/commands, screen capture,
encoding, Cast session and HLS request/errors. The current file rotates at
2 MiB, retaining three older files. PINs and private keys are never logged.
Settings → Help & diagnostics has a share action.

The iOS 27 screen-mirroring encoder now anchors HLS fragments at the first
capture presentation timestamp and reports the full `NSError` domain/code
and underlying failure. If HEVC 4K fails to initialize it retries once at
1080p H.264. The HTTP server requires an actual Wi-Fi (`en0`) IPv4
address, fixes `sockaddr_in.sin_addr` handling and rejects cellular/VPN
addresses such as the previously observed `16.2.0.0`. We do **not**
assert successful Chromecast playback or audio synchronization without a
physical-device test. Protected content may remain unavailable.

## Connected TV picker and Google Cast session handoff (v1.4.1)

The **My TV** section is the only place an actively connected receiver appears.
**Nearby televisions** lists only other discovered devices. A unique matching
friendly name also handles the case where a saved receiver uses a `.local`
hostname but Bonjour resolves it to an IPv4 address.

Screen mirroring now caches the Google Cast SDK's selected `GCKDevice` and
requests a Cast session **before** opening the iOS screen-sharing picker.
This avoids losing the selected device when the system picker suspends SDK
device discovery. It postpones the live media LOAD until at least one HLS
fragment has been encoded. If the Cast session resumes after the picker,
the pending media URL is loaded then.

A late Bonjour `-72000` browser error is nonfatal once at least one TV has
already resolved successfully; failure information remains available for scans
that find no usable devices.

**Physical test still required:** a successful HLS segment and successful
Cast session startup do not prove the Chromecast actually started decoding
video/audio. Check the file logs under Files → On My iPhone → CastDeck → Logs.

## License

MIT. Independent application; not affiliated with Google.
