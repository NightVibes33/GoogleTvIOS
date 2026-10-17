import Foundation

/// Keys aligned with Android TV Remote v2 / Windows CastDeck remote.
enum TVKey: String {
    case power = "POWER"
    case back = "BACK"
    case home = "HOME"
    case up = "DPAD_UP"
    case down = "DPAD_DOWN"
    case left = "DPAD_LEFT"
    case right = "DPAD_RIGHT"
    case ok = "DPAD_CENTER"
    case volumeUp = "VOLUME_UP"
    case volumeDown = "VOLUME_DOWN"
    case volumeMute = "VOLUME_MUTE"
    case playPause = "MEDIA_PLAY_PAUSE"
    case searchStartLong = "SEARCH_START_LONG"
    case searchEndLong = "SEARCH_END_LONG"
}
