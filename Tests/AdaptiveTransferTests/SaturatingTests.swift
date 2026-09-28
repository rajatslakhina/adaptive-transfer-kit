import XCTest
@testable import AdaptiveTransfer

/// These are the tests that stop a crash report, not the ones that prove a
/// feature. Every case here is an expression that traps if written naively.
final class SaturatingTests: XCTestCase {

    func testAddSaturatesInsteadOfOverflowing() {
        XCTAssertEqual(Saturating.add(Int.max, 1), Int.max)
        XCTAssertEqual(Saturating.add(Int.min, -1), Int.min)
        XCTAssertEqual(Saturating.add(Int.max, Int.max), Int.max)
        XCTAssertEqual(Saturating.add(3, 4), 7)
    }

    func testSubtractSaturates() {
        XCTAssertEqual(Saturating.subtract(Int.min, 1), Int.min)
        XCTAssertEqual(Saturating.subtract(Int.max, -1), Int.max)
        XCTAssertEqual(Saturating.subtract(10, 4), 6)
    }

    func testMultiplySaturatesWithCorrectSign() {
        XCTAssertEqual(Saturating.multiply(Int.max, 2), Int.max)
        XCTAssertEqual(Saturating.multiply(Int.max, -2), Int.min)
        XCTAssertEqual(Saturating.multiply(Int.min, -1), Int.max)
        XCTAssertEqual(Saturating.multiply(-6, 7), -42)
    }

    func testDivideHandlesZeroAndTheOneOverflowingDivision() {
        XCTAssertEqual(Saturating.divide(10, by: 0, fallback: -1), -1)
        XCTAssertEqual(Saturating.divide(Int.min, by: -1), Int.max)
        XCTAssertEqual(Saturating.divide(9, by: 2), 4)
    }

    func testRemainderHandlesZeroAndIntMin() {
        XCTAssertEqual(Saturating.remainder(10, 0, fallback: 7), 7)
        XCTAssertEqual(Saturating.remainder(Int.min, -1), 0)
        XCTAssertEqual(Saturating.remainder(10, 3), 1)
    }

    func testCeilingDivideNeverOverflows() {
        // The naive `(a + b - 1) / b` overflows for exactly this input.
        XCTAssertEqual(Saturating.ceilingDivide(Int.max, by: 2), (Int.max / 2) + 1)
        XCTAssertEqual(Saturating.ceilingDivide(10, by: 3), 4)
        XCTAssertEqual(Saturating.ceilingDivide(9, by: 3), 3)
        XCTAssertEqual(Saturating.ceilingDivide(0, by: 3), 0)
        XCTAssertEqual(Saturating.ceilingDivide(10, by: 0), 0)
        XCTAssertEqual(Saturating.ceilingDivide(-5, by: 3), 0)
    }

    func testDoubleToIntHandlesNaNInfinityAndOutOfRange() {
        XCTAssertEqual(Saturating.int(Double.nan), 0)
        XCTAssertEqual(Saturating.int(Double.infinity), Int.max)
        XCTAssertEqual(Saturating.int(-Double.infinity), Int.min)
        // 2^64 is well past Int.max on 64-bit and astronomically past it on 32-bit.
        XCTAssertEqual(Saturating.int(1.8446744073709552e19), Int.max)
        XCTAssertEqual(Saturating.int(-1.8446744073709552e19), Int.min)
        XCTAssertEqual(Saturating.int(3.9), 3)
        XCTAssertEqual(Saturating.int(-3.9), -3)
    }

    func testDoubleToIntAtExactlyDoubleOfIntMax() {
        // `Double(Int.max)` rounds UP to 2^63, which is not representable.
        // `Int(Double(Int.max))` traps. This must not.
        XCTAssertEqual(Saturating.int(Double(Int.max)), Int.max)
        XCTAssertEqual(Saturating.int(Double(Int.min)), Int.min)
    }

    func testClampedConversion() {
        XCTAssertEqual(Saturating.int(Double.nan, clampedTo: 1...64), 1)
        XCTAssertEqual(Saturating.int(Double.infinity, clampedTo: 1...64), 64)
        XCTAssertEqual(Saturating.int(7.9, clampedTo: 1...64), 7)
    }

    func testRatioRefusesToProduceNonFiniteValues() {
        XCTAssertEqual(Saturating.ratio(1, 0, fallback: 42), 42)
        XCTAssertEqual(Saturating.ratio(Double.nan, 1, fallback: 42), 42)
        XCTAssertEqual(Saturating.ratio(1, Double.nan, fallback: 42), 42)
        XCTAssertEqual(Saturating.ratio(1, 4, fallback: 42), 0.25)
    }
}
