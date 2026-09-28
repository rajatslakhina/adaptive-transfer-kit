/// A concurrency limit the client *discovers* instead of being told.
///
/// ## The problem this exists to solve
///
/// Almost every upload path in a shipping iOS app contains a line like
/// `maxConcurrentOperationCount = 4`. That number is a guess about capacity
/// that belongs to somebody else — the server's, the carrier's, the shared
/// tenancy the server happens to be in this afternoon — compiled into the
/// client and shipped to the whole fleet. It is wrong in both directions, and
/// only one of those directions is visible:
///
/// * Too low, and you leave throughput on the table on good networks. Someone
///   notices, and the number goes up.
/// * Too high, and throughput does **not** fall. The excess work moves into a
///   queue you do not own and cannot see. By Little's Law the residence time
///   of that queue grows with its depth while the completion rate stays flat,
///   so your throughput dashboard looks healthy while the user watches a
///   spinner. There is no error to alert on.
///
/// The second failure is the reason a fixed limit is the wrong shape of
/// answer, not merely a badly-tuned one. Capacity is not a constant, so the
/// client has to measure it.
///
/// ## How it measures
///
/// Latency is the signal. If the server can absorb the current offered load,
/// round-trip time sits at its no-load floor. The moment requests begin
/// queueing anywhere on the path, RTT rises *before* anything starts failing —
/// which is what makes it an early signal rather than a post-mortem one.
///
///     gradient  = clamp(noLoadRTT / observedRTT, minimumGradient, 1.0)
///     headroom  = queueFactor * sqrt(limit)
///     newLimit  = limit * gradient + headroom
///     limit    += smoothing * (newLimit - limit)
///
/// A gradient of 1.0 means "no queueing detected", and the `headroom` term is
/// what lets the limit climb — additively, and proportional to `sqrt(limit)`
/// so that probing gets more cautious as the limit gets larger. A gradient
/// below 1.0 multiplies the limit down. That is additive-increase /
/// multiplicative-decrease, the same asymmetry congestion control has used
/// since Jacobson, and for the same reason: over-estimating capacity is much
/// more expensive than under-estimating it.
///
/// The shape follows TCP Vegas and Netflix's `concurrency-limits`, which is a
/// deliberate choice to use a control law with two decades of production
/// evidence behind it rather than invent one.
///
/// ## What was rejected
///
/// * **Token-bucket rate limiting.** Bounds requests per second, which is a
///   different quantity. A rate that is safe at 40 ms RTT is an unbounded
///   queue at 400 ms, because a rate limiter has no idea how much work is
///   still outstanding.
/// * **Error-rate-driven backoff** (shrink when requests start failing).
///   Correct, and far too late: by the time a request is dropped the queue has
///   already been deep for seconds and users have already waited.
/// * **A server-advertised limit** (`Retry-After`, a concurrency header). A
///   better signal where it exists, and worth preferring — but it requires the
///   server to know its own per-client share, it does not survive a
///   misbehaving CDN in the middle, and it is absent in every third-party
///   upload endpoint this would actually have to work against. The gradient
///   controller degrades to "no queueing observed" when it is wrong, which is
///   a safe failure.
///
/// ## Concurrency
///
/// A `struct`, with no clock and no I/O. All of its inputs arrive as
/// `RequestSample` values. That is what makes the control law testable as a
/// pure function and keeps every suspension point out of the state machine —
/// see `TransferCoordinator` for how the one actor in this package keeps
/// limiter mutation and the `await` boundary apart.
public struct GradientLimiter: ConcurrencyLimiter {

    public struct Configuration: Sendable {
        /// The limit never goes below this. One in-flight request is the
        /// smallest useful answer; zero is a deadlock.
        public var minimumLimit: Int
        /// The limit never goes above this. Bounds memory and file handles
        /// regardless of what the control law computes.
        public var maximumLimit: Int
        /// Where to start before any evidence has arrived.
        public var initialLimit: Int
        /// Floor on the gradient, which bounds how violently a single slow
        /// sample can cut the limit. 0.5 means "at most halve per sample".
        public var minimumGradient: Double
        /// EWMA weight applied to the newly computed limit. Lower is steadier
        /// and slower to react.
        public var smoothing: Double
        /// Multiplier on the `sqrt(limit)` probing headroom.
        public var queueFactor: Double
        /// Multiplicative cut applied on a drop.
        public var dropPenalty: Double

        public init(
            minimumLimit: Int = 1,
            maximumLimit: Int = 64,
            initialLimit: Int = 4,
            minimumGradient: Double = 0.5,
            smoothing: Double = 0.2,
            queueFactor: Double = 1.0,
            dropPenalty: Double = 0.7
        ) {
            // Every field is sanitised here rather than trusted, because this
            // type is public API and a zero `maximumLimit` or a NaN smoothing
            // factor would otherwise become a deadlock or a trap much later.
            self.minimumLimit = max(1, minimumLimit)
            self.maximumLimit = max(self.minimumLimit, maximumLimit)
            self.initialLimit = min(max(initialLimit, self.minimumLimit), self.maximumLimit)
            self.minimumGradient = Self.sane(minimumGradient, default: 0.5, in: 0.01...1.0)
            self.smoothing = Self.sane(smoothing, default: 0.2, in: 0.01...1.0)
            self.queueFactor = Self.sane(queueFactor, default: 1.0, in: 0.0...8.0)
            self.dropPenalty = Self.sane(dropPenalty, default: 0.7, in: 0.05...1.0)
        }

        private static func sane(
            _ value: Double,
            default fallback: Double,
            in range: ClosedRange<Double>
        ) -> Double {
            guard value.isFinite else { return fallback }
            return min(max(value, range.lowerBound), range.upperBound)
        }

        /// Defaults tuned for a photo/video upload path on a mobile network.
        public static let uploadPipeline = Configuration()
    }

    public let configuration: Configuration

    /// The limit is carried as a `Double` so that additive increases smaller
    /// than one whole request still accumulate. Rounding to `Int` on every
    /// step would make the probing term vanish at any limit above
    /// `1 / queueFactor²` and freeze the controller.
    private var limit: Double
    private var noLoad: DecayingMinimum
    private var observationCount: Int = 0

    public init(configuration: Configuration = .uploadPipeline) {
        self.configuration = configuration
        self.limit = Double(configuration.initialLimit)
        // Seeded high so the first real sample almost certainly lowers it. A
        // low seed would read as "already at the floor" and suppress probing.
        self.noLoad = DecayingMinimum(initialValue: 1.0)
    }

    public var currentLimit: Int {
        Saturating.int(
            limit.rounded(.down),
            clampedTo: configuration.minimumLimit...configuration.maximumLimit
        )
    }

    /// The controller's current estimate of the no-load round-trip time, in
    /// seconds. Exposed for observability: a no-load estimate that has drifted
    /// is the first thing to look at when the limit is stuck.
    public var estimatedNoLoadSeconds: Double { noLoad.value }

    /// Current gradient-derived limit before rounding. Exposed for tests and
    /// dashboards; not part of the control contract.
    public var rawLimit: Double { limit }

    /// How many samples have been folded in.
    public var samplesObserved: Int { observationCount }

    public mutating func observe(_ sample: RequestSample) {
        observationCount = Saturating.add(observationCount, 1)

        switch sample.outcome {
        case .dropped:
            // A drop is the signal of last resort and its RTT is garbage, so
            // it is cut multiplicatively and deliberately never reaches
            // `noLoad`. Folding a 30-second timeout into the floor estimate
            // would raise it and make the controller *less* sensitive exactly
            // when it needs to be more.
            limit = clampToBounds(limit * configuration.dropPenalty)

        case .completed:
            let observedSeconds = Self.seconds(sample.roundTrip)
            // A non-positive or non-finite RTT is a broken measurement, not
            // evidence of infinite capacity. Treated as "no information".
            guard observedSeconds > 0 else { return }

            noLoad.offer(observedSeconds)

            let gradient = min(
                max(
                    Saturating.ratio(noLoad.value, observedSeconds, fallback: 1.0),
                    configuration.minimumGradient
                ),
                1.0
            )

            let headroom = configuration.queueFactor * limit.squareRoot()
            let target = limit * gradient + headroom
            guard target.isFinite else { return }

            limit = clampToBounds(limit + configuration.smoothing * (target - limit))
        }
    }

    private func clampToBounds(_ value: Double) -> Double {
        guard value.isFinite else { return Double(configuration.initialLimit) }
        return min(
            max(value, Double(configuration.minimumLimit)),
            Double(configuration.maximumLimit)
        )
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
