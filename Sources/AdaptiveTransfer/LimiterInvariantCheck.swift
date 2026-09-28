/// An executable statement of what "adaptive" has to mean.
///
/// The README of this package makes a claim: the limiter shrinks when the path
/// starts queueing, and recovers when it stops. A test that only ever runs
/// `GradientLimiter` cannot substantiate that claim, because a check that
/// passes for every input passes for a broken implementation too — which is
/// the definition of a vacuous test.
///
/// So the claim lives here, as a check that takes *any* `ConcurrencyLimiter`,
/// and the test suite runs it twice: once against `GradientLimiter`, asserting
/// it passes, and once against implementations that are wrong on purpose
/// (`FixedLimiter`, `MonotonicLimiter`), asserting it **fails** and naming the
/// invariant it failed. If someone gutted the control law in
/// `GradientLimiter.observe(_:)`, the first assertion turns red.
public enum LimiterInvariantCheck {

    public enum Invariant: String, Sendable, CaseIterable {
        /// Sustained queueing must reduce the limit materially.
        case respondsToQueueing
        /// Once queueing clears, the limit must climb back.
        case recoversAfterQueueing
        /// The limit must never fall below 1; zero is a deadlock.
        case respectsFloor
        /// A dropped request must reduce the limit.
        case respondsToDrops
        /// A quiet, fast path must let the limit grow above its start.
        case probesUpward
    }

    public struct Report: Sendable, Equatable {
        public let failures: [Invariant]
        public let limitBeforeCongestion: Int
        public let limitDuringCongestion: Int
        public let limitAfterRecovery: Int
        public let limitAfterDrop: Int

        public var passed: Bool { failures.isEmpty }
    }

    /// Thresholds the check enforces. Named rather than inlined so the numbers
    /// a reader of the README sees are the numbers CI enforces.
    public static let congestionShrinkCeiling = 0.7   // limit must fall to <= 70%
    public static let recoveryFloor = 0.8             // limit must return to >= 80%

    private static let quietRoundTrip = Duration.milliseconds(20)
    private static let congestedRoundTrip = Duration.milliseconds(200)
    private static let samplesPerPhase = 60

    /// Runs a scripted congestion episode against `limiter` and reports which
    /// invariants it violated.
    ///
    /// The script is: a quiet phase at a 20 ms round trip (the limit should
    /// grow), then a congested phase at 200 ms with the same offered load (a
    /// 10x rise with no drops — unambiguous queueing, so the limit must fall),
    /// then a quiet phase again (it must come back), then a single dropped
    /// request (it must fall again).
    public static func run<L: ConcurrencyLimiter>(_ limiter: L) -> Report {
        var subject = limiter
        var failures: [Invariant] = []

        let startingLimit = subject.currentLimit

        feed(&subject, roundTrip: quietRoundTrip, count: samplesPerPhase)
        let before = subject.currentLimit
        if before <= startingLimit { failures.append(.probesUpward) }

        feed(&subject, roundTrip: congestedRoundTrip, count: samplesPerPhase)
        let during = subject.currentLimit
        if Double(during) > Double(before) * congestionShrinkCeiling {
            failures.append(.respondsToQueueing)
        }

        feed(&subject, roundTrip: quietRoundTrip, count: samplesPerPhase)
        let after = subject.currentLimit
        if Double(after) < Double(before) * recoveryFloor {
            failures.append(.recoversAfterQueueing)
        }

        let beforeDrop = subject.currentLimit
        subject.observe(
            RequestSample(roundTrip: quietRoundTrip, inFlight: beforeDrop, outcome: .dropped)
        )
        let afterDrop = subject.currentLimit
        if afterDrop >= beforeDrop && beforeDrop > 1 {
            failures.append(.respondsToDrops)
        }

        if [startingLimit, before, during, after, afterDrop].contains(where: { $0 < 1 }) {
            failures.append(.respectsFloor)
        }

        return Report(
            failures: failures,
            limitBeforeCongestion: before,
            limitDuringCongestion: during,
            limitAfterRecovery: after,
            limitAfterDrop: afterDrop
        )
    }

    private static func feed<L: ConcurrencyLimiter>(
        _ limiter: inout L,
        roundTrip: Duration,
        count: Int
    ) {
        for _ in 0..<max(0, count) {
            limiter.observe(
                RequestSample(
                    roundTrip: roundTrip,
                    inFlight: limiter.currentLimit,
                    outcome: .completed
                )
            )
        }
    }
}

/// A limiter that grows and never shrinks.
///
/// Shipped in the library, not the test target, for one reason: it is the
/// counterexample `LimiterInvariantCheck` has to reject, and keeping it beside
/// the check makes it obvious that the check has teeth. It is also an honest
/// portrait of a real bug — a controller whose decrease path is behind a
/// condition that never fires reads as "adaptive" in every log line.
public struct MonotonicLimiter: ConcurrencyLimiter {
    private var limit: Int
    private let maximumLimit: Int

    public init(initialLimit: Int = 4, maximumLimit: Int = 64) {
        self.maximumLimit = max(1, maximumLimit)
        self.limit = min(max(1, initialLimit), self.maximumLimit)
    }

    public var currentLimit: Int { limit }

    public mutating func observe(_ sample: RequestSample) {
        guard sample.outcome == .completed else { return }
        limit = min(Saturating.add(limit, 1), maximumLimit)
    }
}
