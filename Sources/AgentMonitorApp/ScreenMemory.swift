import AppKit

/// Remembers where the user put the pet, per display.
///
/// Keyed by the display's UUID rather than its index in `NSScreen.screens`, because
/// that array's order is not stable across reconnects, sleep or arrangement changes.
/// Storing an index means the pet reappears on a different monitor after a dock cycle.
enum ScreenMemory {

    private static let originKey = "pet.origin"
    private static let screenKey = "pet.screenUUID"

    static func uuid(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value))
        else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String?
    }

    static func screen(withUUID uuid: String) -> NSScreen? {
        NSScreen.screens.first { Self.uuid(for: $0) == uuid }
    }

    static func save(origin: NSPoint, screen: NSScreen?) {
        let defaults = UserDefaults.standard
        defaults.set(NSStringFromPoint(origin), forKey: originKey)
        if let screen, let uuid = uuid(for: screen) {
            defaults.set(uuid, forKey: screenKey)
        }
    }

    /// The remembered position, but only if its display is still attached and the
    /// position is still on it. A pet restored onto a monitor that is no longer there
    /// is a pet the user cannot find.
    static func restore(size: NSSize) -> NSPoint? {
        let defaults = UserDefaults.standard
        guard let stored = defaults.string(forKey: originKey) else { return nil }
        let origin = NSPointFromString(stored)

        guard let uuid = defaults.string(forKey: screenKey), let screen = screen(withUUID: uuid)
        else { return nil }

        let frame = NSRect(origin: origin, size: size)
        guard screen.visibleFrame.intersects(frame) else { return nil }
        return origin
    }
}
