import AgentMonitorCore
import AppKit
import Combine
import ServiceManagement

/// Everything the user can set, in one place, persisted to `UserDefaults`.
///
/// Observable so the settings window binds straight to it and the controller reacts to
/// each change as it happens — no "Apply" button, no restart.
@MainActor
final class Preferences: ObservableObject {

    static let shared = Preferences()

    // MARK: Appearance

    /// Side of the pet's square, in points.
    @Published var petSize: Double { didSet { store(petSize, "pet.size") } }
    static let petSizeRange: ClosedRange<Double> = 64...256

    // MARK: Behaviour

    @Published var fadeEnabled: Bool { didSet { store(fadeEnabled, "fade.enabled") } }
    /// Minutes asleep before fading.
    @Published var fadeDelayMinutes: Double { didSet { store(fadeDelayMinutes, "fade.delay") } }
    @Published var fadeOpacity: Double { didSet { store(fadeOpacity, "fade.opacity") } }

    @Published var bubblesEnabled: Bool { didSet { store(bubblesEnabled, "bubble.enabled") } }
    @Published var bubbleSeconds: Double { didSet { store(bubbleSeconds, "bubble.seconds") } }

    /// Hover dwell before the card opens.
    @Published var cardDelay: Double { didSet { store(cardDelay, "card.delay") } }

    // MARK: Attention

    /// A sound when an agent has been blocked on you long enough to escalate to an
    /// interrupt. Off by default: sound is the loudest thing a monitor can do, and
    /// DESIGN.md reserves it for users who ask.
    @Published var soundEnabled: Bool { didSet { store(soundEnabled, "sound.enabled") } }
    @Published var soundName: String { didSet { store(soundName, "sound.name") } }
    /// Do not disturb: no sounds, no captions. The pet still mirrors state — that is
    /// ambient, and silencing it would make the monitor lie.
    @Published var quietMode: Bool { didSet { store(quietMode, "quiet") } }

    // MARK: Sources

    @Published var codexEnabled: Bool { didSet { store(codexEnabled, "source.codex") } }

    private let defaults = UserDefaults.standard

    private init() {
        func value<T>(_ key: String, _ fallback: T) -> T {
            UserDefaults.standard.object(forKey: key) as? T ?? fallback
        }
        petSize = value("pet.size", 132.0)
        fadeEnabled = value("fade.enabled", true)
        fadeDelayMinutes = value("fade.delay", 10.0)
        fadeOpacity = value("fade.opacity", 0.25)
        bubblesEnabled = value("bubble.enabled", true)
        bubbleSeconds = value("bubble.seconds", 6.0)
        cardDelay = value("card.delay", 0.25)
        soundEnabled = value("sound.enabled", false)
        soundName = value("sound.name", "Glass")
        quietMode = value("quiet", false)
        codexEnabled = value("source.codex", true)
    }

    private func store(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }

    var fadePolicy: FadePolicy {
        fadeEnabled ? FadePolicy(delay: fadeDelayMinutes * 60, opacity: fadeOpacity) : .never
    }

    var captionsAllowed: Bool { bubblesEnabled && !quietMode }
    var soundAllowed: Bool { soundEnabled && !quietMode }

    /// Built-in alert sounds, the ones every Mac has.
    static let sounds = ["Glass", "Ping", "Pop", "Purr", "Tink", "Submarine", "Hero", "Funk", "Blow", "Bottle", "Frog", "Morse", "Sosumi", "Basso"]

    func playSound() {
        NSSound(named: NSSound.Name(soundName))?.play()
    }

    // MARK: Launch at login

    /// Registered through `SMAppService`, so it shows up (and can be turned off) in System
    /// Settings → General → Login Items like any other app. Only works from the bundled
    /// app, not from `swift run`.
    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        objectWillChange.send()
    }
}
