/// One observation of a request that has finished.
///
/// The limiter is fed samples rather than reading a clock. That is deliberate:
/// it makes the whole control loop a pure function of its inputs, so the tests
/// below need no sleeping, no virtual clock plumbing and no tolerance windows.
public struct RequestSample: Sendable, Equatable {

    /// What happened to the request.
    public enum Outcome: Sendable, Equatable {
        /// The request completed. `roundTrip` is meaningful.
        case completed
        /// The request was rejected or timed out. `roundTrip` is *not*
        /// meaningful and must never be folded into the no-load estimate — a
        /// request that died at 30s says nothing about the network's floor.
        case dropped
    }

    /// Observed round-trip time. Ignored when `outcome == .dropped`.
    public let roundTrip: Duration
    /// How many requests were in flight when this one was issued.
    public let inFlight: Int
    public let outcome: Outcome

    public init(roundTrip: Duration, inFlight: Int, outcome: Outcome) {
        self.roundTrip = roundTrip
        self.inFlight = max(0, inFlight)
        self.outcome = outcome
    }
}

/// A policy that answers one question: how many requests may be in flight?
///
/// Deliberately tiny. Everything that needs a concurrency decision depends on
/// this and not on `GradientLimiter`, which is what makes the "plug in a
/// knowingly broken implementation and prove the check catches it" tests in
/// `LimiterInvariantCheckTests` possible.
public protocol ConcurrencyLimiter: Sendable {
    /// The number of requests that may currently be in flight. Always `>= 1`.
    var currentLimit: Int { get }
    /// Fold one finished request into the estimate.
    mutating func observe(_ sample: RequestSample)
}

/// The limiter almost every iOS app ships: a number someone picked.
///
/// Kept in the library on purpose. It is the control in
/// `CapacityExperiment`, and it is the deliberately-wrong implementation that
/// `LimiterInvariantCheck` has to reject — a check that only ever sees the
/// good implementation is not a check.
public struct FixedLimiter: ConcurrencyLimiter {
    public let currentLimit: Int

    public init(_ limit: Int) {
        self.currentLimit = max(1, limit)
    }

    public mutating func observe(_ sample: RequestSample) {
        // Intentionally empty: a fixed limit ignores evidence. That is the
        // whole problem this package exists to demonstrate.
    }
}
