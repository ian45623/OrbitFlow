/// Decides what the system volume should be while the microphone is open, and whether to
/// put it back afterwards.
///
/// Pure on purpose: it takes levels in and hands levels out, and whoever owns the device
/// does the writing. That keeps the one rule that matters here testable — a slider the
/// user moved mid-dictation is their choice, and restoring over it would undo it.
public struct AudioDuck: Sendable {
    /// Proportional rather than an absolute floor, so ducking can never raise the volume
    /// of someone who was already listening quietly.
    public static let factor: Float = 0.2

    /// How far the level may drift from what we set and still count as untouched. Devices
    /// quantise the volume scalar to their own steps, so reading back exactly the value
    /// written is not guaranteed.
    static let tolerance: Float = 0.01

    private var saved: Float?
    private var applied: Float?

    public init() {}

    /// - Returns: the level to set, or nil to leave the device alone — it's silent, muted,
    ///   or already ducked (a second duck would save the ducked level as the original).
    public mutating func duck(from current: Float, muted: Bool) -> Float? {
        guard saved == nil, !muted, current > 0 else { return nil }
        let level = current * Self.factor
        saved = current
        applied = level
        return level
    }

    /// - Returns: the level to put back, or nil when there's nothing to restore or the
    ///   user has since chosen a level of their own.
    public mutating func restore(current: Float) -> Float? {
        guard let saved, let applied else { return nil }
        self.saved = nil
        self.applied = nil
        guard abs(current - applied) <= Self.tolerance else { return nil }
        return saved
    }
}
