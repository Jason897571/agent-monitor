import AppKit
import Carbon.HIToolbox

/// A system-wide hotkey, registered through Carbon.
///
/// Carbon's `RegisterEventHotKey` needs **no Accessibility permission**, unlike a
/// `CGEventTap` or a global keyboard monitor. That matters more than its age: P0's
/// acceptance criterion is that the app prompts for nothing at all, and a cold-start
/// Accessibility dialog is the single biggest drop-off point for a menu-bar utility.
///
/// The chosen default is deliberately obscure. A monitor that steals a common chord
/// breaks it in every other app — one shipping competitor took `Ctrl-U` and swallowed
/// readline's kill-line system-wide.
@MainActor
final class GlobalHotkey {

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: @MainActor () -> Void

    /// - Parameters:
    ///   - keyCode: a virtual key code, e.g. `kVK_ANSI_P`.
    ///   - modifiers: Carbon modifier mask, e.g. `controlKey | optionKey | cmdKey`.
    init?(keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
            // Carbon delivers on the main thread; this asserts rather than hops so the
            // keypress is handled in the same turn of the run loop.
            MainActor.assumeIsolated { hotkey.action() }
            return noErr
        }

        guard InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        ) == noErr else { return nil }

        // 'AGMT'
        let identifier = EventHotKeyID(signature: OSType(0x4147_4D54), id: 1)
        guard RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        ) == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            handlerRef = nil
            return nil
        }
    }

    /// Releases the Carbon registrations.
    ///
    /// Explicit rather than in `deinit` because a `deinit` on a main-actor class is
    /// nonisolated under strict concurrency and may not touch these opaque pointers.
    /// The owner calls this on shutdown.
    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }

    /// Control-Option-Command-P. Obscure enough to be safe to claim system-wide.
    static let defaultKeyCode = kVK_ANSI_P
    static let defaultModifiers = controlKey | optionKey | cmdKey
    static let defaultDescription = "⌃⌥⌘P"
}
