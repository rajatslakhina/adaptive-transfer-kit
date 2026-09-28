/// Arithmetic that cannot trap.
///
/// The control loop in this package multiplies and divides numbers that come
/// from measurements — round-trip times, observed queue depths, configured
/// limits. Measurements arrive as `Double` and are turned into `Int` counts,
/// and every one of those conversions is a trap waiting to happen:
///
/// * `Int(someDouble)` traps on `NaN`, on `±Double.infinity`, and on any value
///   outside `Int`'s range. A single divide-by-zero upstream produces `inf`,
///   and the crash lands three frames away from the bug.
/// * `%` and `/` trap when the divisor is zero, and `Int.min / -1` traps on
///   overflow even though the divisor is fine.
/// * `*` and `+` trap on overflow in release builds as well as debug.
///
/// Rather than sprinkle `guard` statements at each site — which is how one
/// gets missed — every arithmetic operation in this package that *could* trap
/// goes through here and saturates instead.
public enum Saturating {

    /// `a + b`, pinned to `Int.min ... Int.max` instead of overflowing.
    public static func add(_ a: Int, _ b: Int) -> Int {
        let (result, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return result }
        return b > 0 ? Int.max : Int.min
    }

    /// `a - b`, pinned to `Int.min ... Int.max` instead of overflowing.
    public static func subtract(_ a: Int, _ b: Int) -> Int {
        let (result, overflow) = a.subtractingReportingOverflow(b)
        guard overflow else { return result }
        return b > 0 ? Int.min : Int.max
    }

    /// `a * b`, pinned to `Int.min ... Int.max` instead of overflowing.
    public static func multiply(_ a: Int, _ b: Int) -> Int {
        let (result, overflow) = a.multipliedReportingOverflow(by: b)
        guard overflow else { return result }
        return (a > 0) == (b > 0) ? Int.max : Int.min
    }

    /// `a / b`. Returns `fallback` when `b == 0`, and `Int.max` for the one
    /// other trapping case, `Int.min / -1`.
    public static func divide(_ a: Int, by b: Int, fallback: Int = 0) -> Int {
        guard b != 0 else { return fallback }
        if a == Int.min && b == -1 { return Int.max }
        return a / b
    }

    /// `a % b`. Returns `fallback` when `b == 0`, and `0` for `Int.min % -1`
    /// (mathematically correct, and the form that traps).
    public static func remainder(_ a: Int, _ b: Int, fallback: Int = 0) -> Int {
        guard b != 0 else { return fallback }
        if a == Int.min && b == -1 { return 0 }
        return a % b
    }

    /// `ceil(a / b)` for non-negative `a`, without ever forming `a + b - 1`
    /// (which is where the naive version overflows).
    public static func ceilingDivide(_ a: Int, by b: Int) -> Int {
        guard b > 0, a > 0 else { return 0 }
        let quotient = a / b
        return a % b == 0 ? quotient : add(quotient, 1)
    }

    /// Converts a `Double` to `Int` without trapping.
    ///
    /// `Double(Int.max)` rounds *up* to exactly 2^63, which is not
    /// representable as `Int`, so the comparison has to be `>=` and the
    /// ceiling has to be derived from `Int.max` rather than written as a
    /// 64-bit literal — `Int` is 32 bits on watchOS.
    public static func int(_ value: Double) -> Int {
        guard !value.isNaN else { return 0 }
        if value >= Double(Int.max) { return Int.max }
        if value <= Double(Int.min) { return Int.min }
        return Int(value)
    }

    /// Converts a `Double` to `Int` and clamps it into `range`.
    public static func int(_ value: Double, clampedTo range: ClosedRange<Int>) -> Int {
        min(max(int(value), range.lowerBound), range.upperBound)
    }

    /// `a / b` in floating point, returning `fallback` when the result would
    /// not be finite (zero divisor, or either operand not finite).
    public static func ratio(_ a: Double, _ b: Double, fallback: Double) -> Double {
        guard a.isFinite, b.isFinite, b != 0 else { return fallback }
        let result = a / b
        return result.isFinite ? result : fallback
    }
}
