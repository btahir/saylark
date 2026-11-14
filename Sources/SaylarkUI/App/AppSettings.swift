import CoreGraphics
import Foundation
import Observation
import SaylarkCore

/// How long take audio is kept on disk.
public enum AudioRetention: Int, CaseIterable, Sendable, Identifiable {
    case oneDay = 1, twoWeeks = 14, thirtyDays = 30, forever = 0

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .oneDay: "1 day"
        case .twoWeeks: "14 days"
        case .thirtyDays: "30 days"
        case .forever: "Forever"
        }
    }
}

/// The user's settings, stored in `UserDefaults` (the standard suite in the app, a private suite in
/// tests and renders). The engine reads the keys it needs (`microphoneUID`, `keepMicReady`,
/// `keepAudioDays`) from the same suite; the keys are listed in `AppSettings.Key`.
@MainActor @Observable public final class AppSettings {
    public enum Key {
        public static let triggerKey = DictationSettingsKey.triggerKey
        public static let sendOnReturn = DictationSettingsKey.sendOnReturn
        public static let sendOnReturnApps = DictationSettingsKey.sendOnReturnApps
        public static let paragraphsFromPauses = DictationSettingsKey.paragraphsFromPauses
        public static let copyWhenNoField = DictationSettingsKey.copyWhenNoField
        public static let voiceVisual = "voiceVisual"
        public static let liveWords = "liveWords"
        public static let accent = "accent"
        public static let keepAudioDays = "keepAudioDays"
        public static let sounds = "sounds"
        public static let microphoneUID = "microphoneUID"
        public static let keepMicReady = "keepMicReady"
        public static let onboarded = "onboarded"
    }

    @ObservationIgnored private let defaults: UserDefaults

    public var voiceVisual: VoiceVisualKind { didSet { defaults.set(voiceVisual.rawValue, forKey: Key.voiceVisual) } }
    public var liveWords: Bool { didSet { defaults.set(liveWords, forKey: Key.liveWords) } }
    public var accent: PillAccent { didSet { defaults.set(accent.rawValue, forKey: Key.accent) } }
    public var keepAudio: AudioRetention { didSet { defaults.set(keepAudio.rawValue, forKey: Key.keepAudioDays) } }
    public var sounds: Bool { didSet { defaults.set(sounds, forKey: Key.sounds) } }
    /// Core Audio unique ID of the chosen input, or nil for "Automatic" (pinned, then USB, then built-in).
    public var microphoneUID: String? { didSet { defaults.set(microphoneUID, forKey: Key.microphoneUID) } }
    /// Advanced: keep the mic open between takes for instant pre-roll (shows the orange dot).
    public var keepMicReady: Bool { didSet { defaults.set(keepMicReady, forKey: Key.keepMicReady) } }
    public var onboarded: Bool { didSet { defaults.set(onboarded, forKey: Key.onboarded) } }
    /// Which key starts a take.
    public var triggerKey: TriggerKey { didSet { defaults.set(triggerKey.rawValue, forKey: Key.triggerKey) } }
    /// Return during a take: stop, paste and send. On for the agent apps by default.
    public var sendOnReturn: SendOnReturn { didSet { defaults.set(sendOnReturn.rawValue, forKey: Key.sendOnReturn) } }
    /// Bundle IDs for "In chosen apps". Written only once the user edits the list, so an untouched
    /// list keeps following `DictationSettingsKey.defaultSendOnReturnApps`.
    public var sendOnReturnApps: [String] { didSet { defaults.set(sendOnReturnApps, forKey: Key.sendOnReturnApps) } }
    /// A long pause inside a long take becomes a paragraph break.
    public var paragraphsFromPauses: Bool { didSet { defaults.set(paragraphsFromPauses, forKey: Key.paragraphsFromPauses) } }
    /// No text field focused: put the text on the clipboard right away instead of offering Copy.
    public var copyWhenNoField: Bool { didSet { defaults.set(copyWhenNoField, forKey: Key.copyWhenNoField) } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        voiceVisual = defaults.string(forKey: Key.voiceVisual).flatMap(VoiceVisualKind.init(rawValue:)) ?? .seeds
        liveWords = defaults.object(forKey: Key.liveWords) as? Bool ?? false
        accent = defaults.string(forKey: Key.accent).flatMap(PillAccent.init(rawValue:)) ?? .ember
        keepAudio = (defaults.object(forKey: Key.keepAudioDays) as? Int).flatMap(AudioRetention.init(rawValue:)) ?? .thirtyDays
        sounds = defaults.object(forKey: Key.sounds) as? Bool ?? false
        microphoneUID = defaults.string(forKey: Key.microphoneUID)
        keepMicReady = defaults.object(forKey: Key.keepMicReady) as? Bool ?? false
        onboarded = defaults.object(forKey: Key.onboarded) as? Bool ?? false
        triggerKey = defaults.string(forKey: Key.triggerKey).flatMap(TriggerKey.init(rawValue:)) ?? .fn
        sendOnReturn = defaults.string(forKey: Key.sendOnReturn).flatMap(SendOnReturn.init(rawValue:)) ?? .listedApps
        sendOnReturnApps = defaults.stringArray(forKey: Key.sendOnReturnApps) ?? DictationSettingsKey.defaultSendOnReturnApps
        paragraphsFromPauses = defaults.object(forKey: Key.paragraphsFromPauses) as? Bool ?? true
        copyWhenNoField = defaults.object(forKey: Key.copyWhenNoField) as? Bool ?? false
        // Shadow mode is gone: Saylark always pastes. Drop the old choice so nothing reads it.
        defaults.removeObject(forKey: "mode")
        // The engine reads the same keys from this suite. Registering the defaults makes a key the
        // user never touched read the same on both sides, without writing anything.
        defaults.register(defaults: [
            Key.triggerKey: TriggerKey.fn.rawValue,
            Key.sendOnReturn: SendOnReturn.listedApps.rawValue,
            Key.paragraphsFromPauses: true,
            Key.copyWhenNoField: false,
        ])
    }

    /// The pill theme these settings describe.
    public var pillTheme: PillTheme {
        PillTheme(accent: accent, visual: voiceVisual, liveWords: liveWords, reduceMotion: false)
    }
}

/// The accents offered in Settings (White is a lab control, not a user choice).
public extension PillAccent {
    static let userChoices: [PillAccent] = [.ember, .mint, .amber]

    var title: String { rawValue.capitalized }

    /// The accent for controls and text in Saylark's windows (buttons, links, sidebar icons). The
    /// pill's colours are tuned for a black pill; on a window they are too light for white button
    /// text or for text on white (amber was 1.6:1). These deeper shades keep the hue and reach
    /// about 3.5:1 or better against white text and both window backgrounds.
    var controlColor: CGColor {
        switch self {
        case .ember: CGColor(srgbRed: 0.878, green: 0.314, blue: 0.165, alpha: 1)   // #E0502A
        case .mint: CGColor(srgbRed: 0.071, green: 0.576, blue: 0.420, alpha: 1)    // #12936B
        case .amber: CGColor(srgbRed: 0.722, green: 0.478, blue: 0.0, alpha: 1)     // #B87A00
        case .white: CGColor(srgbRed: 0.42, green: 0.42, blue: 0.44, alpha: 1)
        }
    }
}

public extension VoiceVisualKind {
    var title: String { rawValue.capitalized }

    var blurb: String {
        switch self {
        case .trace: "Your voice as a scrolling trace"
        case .wave: "A thin line that rides your voice"
        case .seeds: "Five dots that swell as you speak"
        }
    }
}

public extension TriggerKey {
    static let userChoices: [TriggerKey] = [.fn, .rightOption, .rightCommand]

    var title: String {
        switch self {
        case .fn: "Fn"
        case .rightOption: "Right Option"
        case .rightCommand: "Right Command"
        }
    }

    /// The label on the keycap drawn next to the picker.
    var keycap: String {
        switch self {
        case .fn: "fn"
        case .rightOption: "right \u{2325}"
        case .rightCommand: "right \u{2318}"
        }
    }

    /// What the key does, for the line beside the picker.
    var gestureHint: String { "Hold to talk, double-tap for hands-free" }
}

public extension SendOnReturn {
    var title: String {
        switch self {
        case .off: "Off"
        case .listedApps: "In chosen apps"
        case .everywhere: "Everywhere"
        }
    }

    static let explanation = "While you dictate, press Return to stop, paste and send."
}
