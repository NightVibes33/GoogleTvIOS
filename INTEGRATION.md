# Protocol integration

The `AndroidTVRemoteControl` package is linked in `project.yml` and wired in `Sources/Services/AndroidTVRemoteBridge.swift`.

The active client owns a TLS pairing session, a remote v2 connection, and a local keychain identity. It explicitly awaits the TV's `.waitingCode`, `.successPaired` and `.paired` states. Connection failures and timeouts are surfaced in the UI and logged without exposing PINs.

Pairing is available on TCP 6467; remote v2 is available on TCP 6466. The TV and iPhone must be on a reachable local network. Inbound Android TV state notifications and deep links depend on receiver firmware.

## Limitations

This is **not** a generic original-Chromecast remote. Cast-only receivers can be discovered but require implementing the Google Cast V2 control protocol separately. iPhone mic voice streaming is unavailable with the linked package and is intentionally not represented as working. The upstream TLS package currently accepts server certificates without certificate pinning; avoid untrusted networks.

On-device acceptance criteria: fresh install → device scan → TV-generated PIN → verified connection → D-pad and volume commands actually change TV state → terminate and relaunch app → reconnect → revoke TV pairing and confirm the re-pair flow.
