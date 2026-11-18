import SwiftUI

/// How a lyric line follows an automatic scroll: the sheet moves on one spring, and a line
/// `along` the view (0 at the leading edge, 1 at the trailing one) also trails it on a softer
/// spring of its own, so lines further along start later and settle last.
/// Adapted from Sonora's lyrics (idea and tuning only).
struct LyricsLagAnimation: CustomAnimation {
    var along: Double

    static let sheet = (stiffness: 170.0, damping: 23.0)
    static let row = (stiffness: 210.0, damping: 22.0)
    /// How much lower the last line's row spring frequency is.
    static let stagger = 0.4
    /// How much of the sheet's movement the last line skips at first.
    static let trail = 1.0
    private static let step = 1.0 / 240
    private static let rest = 0.0005

    func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        guard let remaining = Self.remaining(at: time, along: along) else { return nil }
        return value.scaled(by: 1 - remaining)
    }

    /// The share of the distance a line has still to go, or nil once it rests.
    static func remaining(at time: TimeInterval, along: Double) -> Double? {
        let along = min(max(along, 0), 1)
        let frequency = 1 - stagger * along
        let rowStiffness = row.stiffness * frequency * frequency
        let rowDamping = row.damping * frequency
        let skip = trail * along

        var sheetPosition = 1.0, sheetVelocity = 0.0
        var drift = 0.0, driftVelocity = 0.0
        var t = 0.0
        while t < time {
            let dt = min(step, time - t)
            sheetVelocity += (-sheet.stiffness * sheetPosition - sheet.damping * sheetVelocity) * dt
            let moved = sheetVelocity * dt
            sheetPosition += moved
            driftVelocity += (-rowStiffness * drift - rowDamping * driftVelocity) * dt
            drift += driftVelocity * dt - moved * skip
            t += dt
        }
        let remaining = sheetPosition + drift
        let moving = abs(sheetVelocity) + abs(driftVelocity)
        if time > 0, abs(remaining) < rest, moving < rest * 10 { return nil }
        return remaining
    }
}
