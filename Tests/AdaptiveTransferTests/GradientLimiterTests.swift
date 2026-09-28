import XCTest
@testable import AdaptiveTransfer

final class GradientLimiterTests: XCTestCase {

    private func feed(
        _ limiter: inout GradientLimiter,
        milliseconds: Int,
        count: Int,
        outcome: RequestSample.Outcome = .completed
    ) {
        for _ in 0..<count {
            limiter.observe(
                RequestSample(
                    roundTrip: .milliseconds(milliseconds),
                    inFlight: limiter.currentLimit,
                    outcome: outcome
                )
            )
        }
    }

    func testStartsAtConfiguredInitialLimit() {
        let limiter = GradientLimiter(
            configuration: .init(minimumLimit: 2, maximumLimit: 32, initialLimit: 6)
        )
        XCTAssertEqual(limiter.currentLimit, 6)
    }

    func testConfigurationSanitisesNonsense() {
        let configuration = GradientLimiter.Configuration(
            minimumLimit: 0,
            maximumLimit: -5,
            initialLimit: 1_000,
            minimumGradient: .nan,
            smoothing: .infinity,
            queueFactor: -3,
            dropPenalty: 0
        )
        XCTAssertEqual(configuration.minimumLimit, 1)
        XCTAssertEqual(configuration.maximumLimit, 1)
        XCTAssertEqual(configuration.initialLimit, 1)
        XCTAssertEqual(configuration.minimumGradient, 0.5)
        // A non-finite value falls back to the default rather than clamping
        // to the ceiling: `infinity` is not "as much smoothing as possible",
        // it is a broken input, and the safe reading of a broken input is the
        // documented default.
        XCTAssertEqual(configuration.smoothing, 0.2)
        XCTAssertEqual(configuration.queueFactor, 0.0)
        XCTAssertEqual(configuration.dropPenalty, 0.05)
    }

    func testLimitClimbsOnAQuietPath() {
        var limiter = GradientLimiter()
        let start = limiter.currentLimit
        feed(&limiter, milliseconds: 20, count: 80)
        XCTAssertGreaterThan(limiter.currentLimit, start)
        XCTAssertLessThanOrEqual(limiter.currentLimit, limiter.configuration.maximumLimit)
    }

    func testLimitNeverExceedsMaximum() {
        var limiter = GradientLimiter(
            configuration: .init(minimumLimit: 1, maximumLimit: 12, initialLimit: 4)
        )
        feed(&limiter, milliseconds: 5, count: 5_000)
        XCTAssertEqual(limiter.currentLimit, 12)
    }

    func testLimitNeverFallsBelowMinimum() {
        var limiter = GradientLimiter(
            configuration: .init(minimumLimit: 2, maximumLimit: 64, initialLimit: 16)
        )
        feed(&limiter, milliseconds: 20, count: 200, outcome: .dropped)
        XCTAssertEqual(limiter.currentLimit, 2)
    }

    func testDroppedSampleDoesNotPoisonTheNoLoadEstimate() {
        var limiter = GradientLimiter()
        feed(&limiter, milliseconds: 20, count: 60)
        let noLoadBefore = limiter.estimatedNoLoadSeconds
        // A 30-second timeout. If this were folded into the floor estimate the
        // controller would read every subsequent 20 ms sample as "wildly
        // faster than no-load" and stop reacting to congestion entirely.
        limiter.observe(
            RequestSample(roundTrip: .seconds(30), inFlight: 8, outcome: .dropped)
        )
        XCTAssertEqual(limiter.estimatedNoLoadSeconds, noLoadBefore)
    }

    func testZeroAndNegativeRoundTripsAreIgnoredRatherThanTrapping() {
        var limiter = GradientLimiter()
        feed(&limiter, milliseconds: 20, count: 40)
        let before = limiter.rawLimit
        limiter.observe(RequestSample(roundTrip: .zero, inFlight: 4, outcome: .completed))
        limiter.observe(
            RequestSample(roundTrip: .milliseconds(-5), inFlight: 4, outcome: .completed)
        )
        XCTAssertEqual(limiter.rawLimit, before, accuracy: 1e-12)
    }

    func testASingleSlowSampleCannotCutTheLimitBelowTheGradientFloor() {
        var limiter = GradientLimiter(
            configuration: .init(initialLimit: 32, minimumGradient: 0.5, smoothing: 1.0)
        )
        feed(&limiter, milliseconds: 10, count: 1)   // primes the floor at 10 ms
        let before = limiter.rawLimit
        // A 100x slower sample. Gradient is floored at 0.5, so the limit can
        // fall by at most half in one step, plus the probing headroom.
        limiter.observe(
            RequestSample(roundTrip: .seconds(1), inFlight: 32, outcome: .completed)
        )
        XCTAssertGreaterThanOrEqual(limiter.rawLimit, before * 0.5)
    }

    func testSamplesObservedCounts() {
        var limiter = GradientLimiter()
        feed(&limiter, milliseconds: 20, count: 7)
        limiter.observe(RequestSample(roundTrip: .zero, inFlight: 1, outcome: .dropped))
        XCTAssertEqual(limiter.samplesObserved, 8)
    }
}
