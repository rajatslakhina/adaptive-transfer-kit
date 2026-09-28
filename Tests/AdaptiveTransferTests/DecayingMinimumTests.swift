import XCTest
@testable import AdaptiveTransfer

final class DecayingMinimumTests: XCTestCase {

    func testAdoptsTheFirstSampleImmediately() {
        var minimum = DecayingMinimum(initialValue: 1.0)
        XCTAssertFalse(minimum.isPrimed)
        minimum.offer(0.04)
        XCTAssertTrue(minimum.isPrimed)
        XCTAssertEqual(minimum.value, 0.04, accuracy: 1e-12)
    }

    func testLowerSamplesWinAtOnce() {
        var minimum = DecayingMinimum(initialValue: 1.0)
        minimum.offer(0.04)
        minimum.offer(0.01)
        XCTAssertEqual(minimum.value, 0.01, accuracy: 1e-12)
    }

    /// The bug this type exists to prevent: one lucky low sample pinning the
    /// floor forever, which collapses the limiter's gradient on any slower
    /// network for the rest of the process's life.
    func testAStaleFloorDecaysUpwardTowardCurrentConditions() {
        var minimum = DecayingMinimum(initialValue: 1.0, decayFactor: 1.1, decayInterval: 5)
        minimum.offer(0.008)                       // the lucky sample
        for _ in 0..<40 { minimum.offer(0.060) }   // the new normal
        XCTAssertGreaterThan(minimum.value, 0.008)
        XCTAssertLessThanOrEqual(minimum.value, 0.060)
    }

    func testDecayNeverOvershootsTheSampleKeepingItHonest() {
        var minimum = DecayingMinimum(initialValue: 1.0, decayFactor: 4.0, decayInterval: 1)
        minimum.offer(0.010)
        for _ in 0..<50 { minimum.offer(0.020) }
        // Even with an absurd decay factor the floor cannot rise above the
        // observed samples; otherwise the gradient reads 1.0 forever and the
        // controller is silently disabled.
        XCTAssertLessThanOrEqual(minimum.value, 0.020)
    }

    func testRejectsNonFiniteAndNonPositiveSamples() {
        var minimum = DecayingMinimum(initialValue: 0.5)
        minimum.offer(.nan)
        minimum.offer(.infinity)
        minimum.offer(0)
        minimum.offer(-1)
        XCTAssertFalse(minimum.isPrimed)
        XCTAssertEqual(minimum.value, 0.5, accuracy: 1e-12)
    }

    func testSanitisesItsOwnConfiguration() {
        let minimum = DecayingMinimum(initialValue: .nan, decayFactor: 0.5, decayInterval: -3)
        XCTAssertEqual(minimum.value, 1.0, accuracy: 1e-12)
        XCTAssertEqual(minimum.decayFactor, 1.05, accuracy: 1e-12)
        XCTAssertEqual(minimum.decayInterval, 1)
    }
}
