import XCTest
@testable import AdaptiveTransfer

/// The point of this file is the *second* test, not the first.
///
/// Asserting that `GradientLimiter` passes `LimiterInvariantCheck` proves
/// nothing on its own — a check that returns `.passed` unconditionally would
/// satisfy it. So the same check is run against two implementations that are
/// wrong in the two ways that matter, and it has to reject both by name.
final class LimiterInvariantCheckTests: XCTestCase {

    func testGradientLimiterPassesTheInvariantCheck() {
        let report = LimiterInvariantCheck.run(GradientLimiter())
        XCTAssertTrue(
            report.passed,
            "GradientLimiter violated: \(report.failures.map(\.rawValue))"
        )
        XCTAssertGreaterThan(report.limitBeforeCongestion, 4)
        XCTAssertLessThan(report.limitDuringCongestion, report.limitBeforeCongestion)
        XCTAssertGreaterThan(report.limitAfterRecovery, report.limitDuringCongestion)
    }

    /// A fixed limit is the implementation this whole package argues against.
    /// The check must catch it, and must catch it for the right reason.
    func testFixedLimiterFailsTheInvariantCheck() {
        let report = LimiterInvariantCheck.run(FixedLimiter(8))
        XCTAssertFalse(report.passed, "a fixed limit must not pass an adaptiveness check")
        XCTAssertTrue(report.failures.contains(.respondsToQueueing))
        XCTAssertTrue(report.failures.contains(.respondsToDrops))
        XCTAssertTrue(report.failures.contains(.probesUpward))
        XCTAssertEqual(report.limitDuringCongestion, 8)
    }

    /// A controller whose decrease path never fires. This is the realistic bug:
    /// it grows, it logs sensible limits, and it looks adaptive right up to the
    /// moment capacity drops.
    func testMonotonicLimiterFailsTheInvariantCheck() {
        let report = LimiterInvariantCheck.run(MonotonicLimiter())
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains(.respondsToQueueing))
        XCTAssertTrue(report.failures.contains(.respondsToDrops))
        // It does probe upward — so that invariant must *not* be reported,
        // which is what shows the check discriminates rather than blanket-fails
        // anything that is not `GradientLimiter`.
        XCTAssertFalse(report.failures.contains(.probesUpward))
    }

    /// The check's thresholds are the numbers quoted in the README. Pinning
    /// them here means a future loosening of the gate shows up as a diff in
    /// this file rather than as prose that quietly stopped being true.
    func testPublishedThresholds() {
        XCTAssertEqual(LimiterInvariantCheck.congestionShrinkCeiling, 0.7)
        XCTAssertEqual(LimiterInvariantCheck.recoveryFloor, 0.8)
    }
}
