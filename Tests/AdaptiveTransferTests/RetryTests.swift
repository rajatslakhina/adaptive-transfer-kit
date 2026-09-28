import XCTest
@testable import AdaptiveTransfer

final class RetryTests: XCTestCase {

    func testFirstAttemptIsImmediate() {
        var jitter = JitterSource(seed: 1)
        XCTAssertEqual(RetryPolicy.default.delay(beforeAttempt: 1, jitter: &jitter), .zero)
        XCTAssertEqual(RetryPolicy.default.delay(beforeAttempt: 0, jitter: &jitter), .zero)
        XCTAssertEqual(RetryPolicy.default.delay(beforeAttempt: -3, jitter: &jitter), .zero)
    }

    func testDelayIsCappedRatherThanOverflowing() {
        let policy = RetryPolicy(
            maximumAttemptsPerChunk: 100,
            baseDelay: .seconds(1),
            multiplier: 10,
            maximumDelay: .seconds(30)
        )
        var jitter = JitterSource(seed: 99)
        // 10^999 is `+infinity` as a Double; the naive version then converts it
        // to Int and traps.
        for attempt in [2, 10, 40, 500, 1_000, Int.max] {
            let delay = policy.delay(beforeAttempt: attempt, jitter: &jitter)
            XCTAssertGreaterThanOrEqual(delay, .zero, "attempt \(attempt)")
            XCTAssertLessThanOrEqual(delay, .seconds(30), "attempt \(attempt)")
        }
    }

    func testJitterIsReproducibleForAGivenSeed() {
        var a = JitterSource(seed: 4_242)
        var b = JitterSource(seed: 4_242)
        let policy = RetryPolicy.default
        for attempt in 2...8 {
            XCTAssertEqual(
                policy.delay(beforeAttempt: attempt, jitter: &a),
                policy.delay(beforeAttempt: attempt, jitter: &b)
            )
        }
    }

    func testJitterActuallyVariesTheDelay() {
        var jitter = JitterSource(seed: 7)
        let policy = RetryPolicy.default
        let delays = (0..<12).map { _ in policy.delay(beforeAttempt: 5, jitter: &jitter) }
        XCTAssertGreaterThan(Set(delays).count, 1, "jitter produced a constant delay")
    }

    func testAZeroSeedStillProducesVaryingJitter() {
        var jitter = JitterSource(seed: 0)
        let values = (0..<8).map { _ in jitter.next() }
        XCTAssertGreaterThan(Set(values).count, 1)
        XCTAssertTrue(values.allSatisfy { $0 >= 0 && $0 < 1 })
    }

    func testTerminalFailuresAreNeverRetried() {
        let policy = RetryPolicy.default
        XCTAssertFalse(policy.shouldRetry(attemptsSoFar: 0, disposition: .terminal))
        XCTAssertTrue(policy.shouldRetry(attemptsSoFar: 0, disposition: .retryable))
        XCTAssertFalse(
            policy.shouldRetry(
                attemptsSoFar: policy.maximumAttemptsPerChunk,
                disposition: .retryable
            )
        )
    }

    func testDispositionMapping() {
        func disposition(_ kind: ChunkTransportError.Kind) -> FailureDisposition {
            ChunkTransportError(kind: kind, chunkIndex: 0).disposition
        }
        XCTAssertEqual(disposition(.throttled), .retryable)
        XCTAssertEqual(disposition(.connectionLost), .retryable)
        XCTAssertEqual(disposition(.timedOut), .retryable)
        XCTAssertEqual(disposition(.rejected), .terminal)
        XCTAssertEqual(disposition(.sourceUnreadable), .terminal)
    }

    // MARK: - Budget shape

    /// Under a per-chunk budget, one permanently broken chunk exhausts its own
    /// attempts and leaves the rest of the transfer alone.
    func testPerChunkBudgetContainsAPoisonedChunk() {
        let policy = RetryPolicy(maximumAttemptsPerChunk: 3)
        var budget = RetryBudget(shape: .perChunk(globalBackstop: 1_000))

        for _ in 0..<3 { budget.recordAttempt(chunkIndex: 7) }
        XCTAssertFalse(budget.permitsRetry(chunkIndex: 7, policy: policy))
        XCTAssertTrue(
            budget.permitsRetry(chunkIndex: 8, policy: policy),
            "a healthy chunk lost its retries to a poisoned one"
        )
    }

    /// The failure mode the default exists to avoid, wired in on purpose: a
    /// single shared pool lets one bad chunk consume every retry in the
    /// transfer, and the healthy chunks are refused.
    func testGlobalOnlyBudgetLetsOnePoisonedChunkStarveTheRest() {
        let policy = RetryPolicy(maximumAttemptsPerChunk: 3)
        var budget = RetryBudget(shape: .globalOnly(attempts: 3))

        for _ in 0..<3 { budget.recordAttempt(chunkIndex: 7) }
        XCTAssertFalse(budget.permitsRetry(chunkIndex: 7, policy: policy))
        XCTAssertFalse(
            budget.permitsRetry(chunkIndex: 8, policy: policy),
            "the global-only shape is supposed to exhibit head-of-line blocking"
        )
    }

    func testGlobalBackstopStillBoundsTotalAttempts() {
        let policy = RetryPolicy(maximumAttemptsPerChunk: 4)
        var budget = RetryBudget(shape: .perChunk(globalBackstop: 10))
        for index in 0..<10 { budget.recordAttempt(chunkIndex: index) }
        XCTAssertEqual(budget.totalAttempts, 10)
        XCTAssertFalse(
            budget.permitsRetry(chunkIndex: 99, policy: policy),
            "per-chunk budgets alone let a wholly-broken transfer retry hundreds of times"
        )
    }

    func testAttemptCountingSaturates() {
        var budget = RetryBudget()
        for _ in 0..<5 { budget.recordAttempt(chunkIndex: 1) }
        XCTAssertEqual(budget.attempts(forChunkIndex: 1), 5)
        XCTAssertEqual(budget.attempts(forChunkIndex: 2), 0)
    }
}
