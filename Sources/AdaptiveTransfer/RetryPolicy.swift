#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Deterministic jitter.
///
/// Retry jitter exists to stop a fleet that all failed at the same instant from
/// all retrying at the same instant. It is also the thing that makes a retry
/// test flaky, so the source is injected: production uses a seeded generator
/// per transfer, tests use a fixed seed and get identical delays every run.
public struct JitterSource: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        // A zero seed makes the generator below emit only zeros forever.
        self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    /// A value in `0..<1`.
    public mutating func next() -> Double {
        // SplitMix64. Chosen because it is four lines, has no allocation, and
        // is trivially reproducible across platforms — none of which is true
        // of `SystemRandomNumberGenerator`.
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        return Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0)  // 2^53
    }
}

/// Whether a failure is worth trying again.
public enum FailureDisposition: Sendable, Equatable {
    /// Transient. Retry after a delay.
    case retryable
    /// Permanent for this chunk. Retrying cannot help.
    case terminal
}

/// Exponential backoff with full jitter and a hard ceiling.
public struct RetryPolicy: Sendable {

    /// Attempts allowed for a single chunk, including the first.
    public let maximumAttemptsPerChunk: Int
    public let baseDelay: Duration
    public let multiplier: Double
    public let maximumDelay: Duration

    public init(
        maximumAttemptsPerChunk: Int = 4,
        baseDelay: Duration = .milliseconds(250),
        multiplier: Double = 2.0,
        maximumDelay: Duration = .seconds(30)
    ) {
        self.maximumAttemptsPerChunk = max(1, maximumAttemptsPerChunk)
        self.baseDelay = baseDelay > .zero ? baseDelay : .milliseconds(1)
        self.multiplier = multiplier.isFinite && multiplier >= 1 ? multiplier : 2.0
        self.maximumDelay = maximumDelay > self.baseDelay ? maximumDelay : self.baseDelay
    }

    public static let `default` = RetryPolicy()

    /// Delay before attempt number `attempt` (1-based; attempt 1 is immediate).
    ///
    /// `multiplier` raised to a large power overflows to `+infinity` long before
    /// `attempt` gets large, so the exponent is capped before the power is
    /// formed rather than the result being checked afterwards.
    public func delay(beforeAttempt attempt: Int, jitter: inout JitterSource) -> Duration {
        guard attempt > 1 else { return .zero }

        let exponent = min(Saturating.subtract(attempt, 1), 32)
        let raw = Self.seconds(baseDelay) * pow(multiplier, Double(exponent))
        let ceiling = Self.seconds(maximumDelay)
        let capped = raw.isFinite ? min(raw, ceiling) : ceiling

        // Full jitter: uniform in `0...capped`, which is what AWS's own
        // analysis found beats "equal jitter" for contention. The trade-off is
        // higher variance in the tail of any single retry.
        let jittered = capped * jitter.next()
        let nanoseconds = Saturating.int(
            (jittered * 1_000_000_000).rounded(),
            clampedTo: 0...Int.max
        )
        return .nanoseconds(nanoseconds)
    }

    public func shouldRetry(attemptsSoFar: Int, disposition: FailureDisposition) -> Bool {
        disposition == .retryable && attemptsSoFar < maximumAttemptsPerChunk
    }

    private static func seconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}

/// Where a retry budget lives.
///
/// This is the design decision in the retry path, and the one that separates a
/// transfer that degrades from one that dies.
///
/// A transfer of 200 chunks in which one chunk is permanently broken — a byte
/// range the server rejects, a proxy that mangles one offset — has two possible
/// behaviours. With a **global** budget, that one chunk's retries consume the
/// whole allowance and the transfer aborts with 40 chunks uploaded: classic
/// head-of-line blocking, where one bad unit of work starves 199 healthy ones.
/// With a **per-chunk** budget, the bad chunk exhausts its own four attempts,
/// is marked terminal, and the other 199 complete; the transfer then fails for
/// a specific, reportable reason instead of a vague timeout.
///
/// Per-chunk is the default here. A global budget is still kept as a second,
/// much larger backstop, because per-chunk budgets alone let a transfer whose
/// *every* chunk is failing retry 800 times before giving up, which is worse
/// for the user and for the server than failing fast.
///
/// `RetryBudgetTests` asserts both halves: the healthy chunks complete under
/// the default policy, and — wiring in `.globalOnly` — that they do **not**.
public struct RetryBudget: Sendable {

    public enum Shape: Sendable, Equatable {
        /// Per-chunk attempts plus a large global backstop. The default.
        case perChunk(globalBackstop: Int)
        /// One shared pool of attempts. Shipped so the head-of-line failure it
        /// causes can be demonstrated rather than asserted in prose.
        case globalOnly(attempts: Int)
    }

    public let shape: Shape
    private var attemptsByChunk: [Int: Int] = [:]
    private var globalAttempts: Int = 0

    public init(shape: Shape = .perChunk(globalBackstop: 1024)) {
        self.shape = shape
    }

    public func attempts(forChunkIndex index: Int) -> Int {
        attemptsByChunk[index] ?? 0
    }

    public var totalAttempts: Int { globalAttempts }

    public mutating func recordAttempt(chunkIndex: Int) {
        attemptsByChunk[chunkIndex] = Saturating.add(attempts(forChunkIndex: chunkIndex), 1)
        globalAttempts = Saturating.add(globalAttempts, 1)
    }

    /// Whether `chunkIndex` may be attempted again under `policy`.
    public func permitsRetry(chunkIndex: Int, policy: RetryPolicy) -> Bool {
        switch shape {
        case .perChunk(let backstop):
            return attempts(forChunkIndex: chunkIndex) < policy.maximumAttemptsPerChunk
                && globalAttempts < backstop
        case .globalOnly(let attempts):
            return globalAttempts < attempts
        }
    }
}
