import Foundation

/// Machine conditions that should make the pet spend less.
///
/// All three signals are free and need no entitlement or permission. They are modelled
/// here rather than in the view because "how much may the pet cost right now" is a
/// policy question, and policy is the part worth testing.
public struct PowerConditions: Sendable, Equatable {

    public enum ThermalPressure: Int, Sendable, Equatable, Comparable, CaseIterable {
        case nominal, fair, serious, critical

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Nothing of the pet is on screen. Animating would be spending for no one.
    public var isOccluded: Bool
    /// Low Power Mode is on — the user has explicitly asked for less.
    public var isLowPower: Bool
    public var thermal: ThermalPressure

    public init(isOccluded: Bool = false, isLowPower: Bool = false, thermal: ThermalPressure = .nominal) {
        self.isOccluded = isOccluded
        self.isLowPower = isLowPower
        self.thermal = thermal
    }

    public static let unconstrained = PowerConditions()

    /// Caps a requested frame rate.
    ///
    /// Note the asymmetry: a cap can only ever lower the rate, never raise it. A pose
    /// that asks for 2 fps stays at 2 fps on a cool idle machine — being unconstrained
    /// is not permission to spend more.
    public func cap(_ requested: Int) -> Int {
        guard requested > 0 else { return 0 }
        if isOccluded { return 0 }

        switch thermal {
        case .critical:
            // The machine is in trouble. A mascot is not what the remaining thermal
            // headroom is for.
            return 0
        case .serious:
            return min(requested, 4)
        case .fair:
            return min(requested, isLowPower ? 6 : 12)
        case .nominal:
            return isLowPower ? min(requested, 12) : requested
        }
    }

    public var isConstrained: Bool { self != .unconstrained }
}
