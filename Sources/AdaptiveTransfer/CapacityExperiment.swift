/// A deterministic discrete-event simulation of one upload against one server.
///
/// ## What this is, and what it is not
///
/// It is a **model**, run in virtual time. Nothing here touches a network, and
/// none of the numbers it produces are measurements of a real device on a real
/// carrier. Saying so plainly matters, because the alternative — publishing
/// wall-clock numbers from one laptop on one Wi-Fi network and calling them
/// evidence — is worse: it is unreproducible, and it would be quoted as though
/// it generalised.
///
/// What a model buys instead is that the comparison is *controlled*. Both
/// strategies face byte-identical conditions, including the same capacity drop
/// at the same virtual instant, so the difference between them is attributable
/// to the control law and nothing else. It also runs in milliseconds on a Linux
/// CI runner with no simulator, which is why the numbers in the README are
/// regenerated and asserted on every push rather than transcribed once.
///
/// The event loop advances to the next completion, updates the limiter with
/// that completion's sample, and admits as much new work as the limiter now
/// allows. Time only moves forward, and every quantity is an integer number of
/// milliseconds, so the result is bit-identical on every platform.
public struct CapacityExperiment: Sendable {

    public struct Scenario: Sendable {
        /// Ceiling on `chunkCount`.
        ///
        /// `run` materialises one element per chunk before the loop starts, so
        /// an unbounded count is an allocation the caller chose by accident.
        /// `ChunkPlanner` caps its plan for the same reason and this type is
        /// its sibling; leaving one of the two uncapped is how a public API
        /// ends up with a segfault behind an innocuous-looking `Int`.
        public static let maximumChunkCount = 1_000_000

        public let chunkCount: Int
        public let server: SimulatedServer
        /// Safety valve: the simulation stops here rather than looping forever
        /// if a limiter ever refuses to admit anything.
        public let horizonMilliseconds: Int

        public init(
            chunkCount: Int,
            server: SimulatedServer,
            horizonMilliseconds: Int = 600_000
        ) {
            self.chunkCount = min(max(0, chunkCount), Self.maximumChunkCount)
            self.server = server
            self.horizonMilliseconds = max(1, horizonMilliseconds)
        }

        /// The scenario quoted in the README: a 300-chunk upload against a
        /// server whose usable capacity is 8 and drops to 2 a fifth of a second
        /// in — a noisy neighbour, a carrier handoff onto a congested cell, or a
        /// backend that just started shedding. The client is told nothing.
        ///
        /// The drop lands early on purpose. A drop near the end of a transfer
        /// is real but uninteresting: most of the work has already completed at
        /// full capacity, so it barely moves the aggregate. Putting it at 200 ms
        /// makes the post-drop regime the one the percentiles describe, which is
        /// the regime a user actually sits through.
        public static let capacityCollapsesMidTransfer = Scenario(
            chunkCount: 300,
            server: SimulatedServer(
                initialCapacity: 8,
                serviceTimeMilliseconds: 40,
                capacityChanges: [.init(atMilliseconds: 200, capacity: 2)]
            )
        )
    }

    public struct Result: Sendable, Equatable {
        /// Virtual time at which the last chunk completed.
        public let completionMilliseconds: Int
        /// Chunks that completed successfully.
        public let completedChunks: Int
        /// Requests the server shed.
        public let droppedRequests: Int
        /// Per-request latency, sorted ascending, in milliseconds.
        public let latenciesMilliseconds: [Int]
        /// Highest concurrency the client ever offered.
        public let peakInFlight: Int
        /// The limit the controller settled on at the end.
        public let finalLimit: Int

        public var medianLatencyMilliseconds: Int { percentile(50) }
        public var p95LatencyMilliseconds: Int { percentile(95) }
        public var p99LatencyMilliseconds: Int { percentile(99) }

        /// Completed chunks per second of virtual time.
        public var throughputPerSecond: Double {
            guard completionMilliseconds > 0 else { return 0 }
            return Double(completedChunks) * 1000.0 / Double(completionMilliseconds)
        }

        /// Floor-rank percentile: `index = floor(p * n / 100) - 1`, clamped
        /// into the array.
        ///
        /// Named for what it does rather than for the textbook method it
        /// resembles. It is *not* nearest-rank, which would round the rank up;
        /// for the 300-sample runs this package publishes the two agree
        /// exactly, but calling it nearest-rank in a doc comment and then
        /// asserting the floor answer in a test is how a definition quietly
        /// becomes "whatever the code did".
        ///
        /// `0` for an empty sample rather than a crash: an experiment that
        /// admitted nothing has no latency, and a trap here would turn a
        /// scheduling bug into a crash report.
        public func percentile(_ percentile: Int) -> Int {
            guard !latenciesMilliseconds.isEmpty else { return 0 }
            let clamped = min(max(percentile, 0), 100)
            let rank = Saturating.divide(
                Saturating.multiply(clamped, latenciesMilliseconds.count),
                by: 100
            )
            let index = min(max(rank - 1, 0), latenciesMilliseconds.count - 1)
            return latenciesMilliseconds[index]
        }
    }

    /// One outstanding request inside the simulation.
    private struct InFlight {
        let chunkIndex: Int
        let issuedAt: Int
        let completesAt: Int
        let shed: Bool
    }

    /// Runs `scenario` against `limiter`.
    ///
    /// Latency is measured **per chunk, end to end**: from the first time that
    /// chunk was admitted to the moment it finally succeeded, including any
    /// attempts the server shed along the way. That choice matters more than it
    /// looks. Measuring only completed *requests* makes load shedding look like
    /// a latency improvement — the shed attempts vanish from the sample and the
    /// survivors were fast — which would have let an over-eager client post
    /// better percentiles than a well-behaved one. The user waits for their
    /// chunk, not for a request.
    public static func run<L: ConcurrencyLimiter>(
        limiter: L,
        scenario: Scenario
    ) -> Result {
        var controller = limiter
        var now = 0
        var pending = Array((0..<scenario.chunkCount).reversed())   // popLast() == FIFO
        var firstAdmittedAt: [Int: Int] = [:]
        var inFlight: [InFlight] = []
        var latencies: [Int] = []
        var completed = 0
        var dropped = 0
        var peakInFlight = 0

        func admit() {
            while !pending.isEmpty, inFlight.count < controller.currentLimit {
                guard let chunkIndex = pending.popLast() else { break }
                let outstanding = Saturating.add(inFlight.count, 1)
                let shed = scenario.server.rejects(atMilliseconds: now, inFlight: outstanding)
                let service = scenario.server.serviceTimeMilliseconds(
                    atMilliseconds: now,
                    inFlight: outstanding
                )
                if firstAdmittedAt[chunkIndex] == nil { firstAdmittedAt[chunkIndex] = now }
                inFlight.append(
                    InFlight(
                        chunkIndex: chunkIndex,
                        issuedAt: now,
                        completesAt: Saturating.add(now, service),
                        shed: shed
                    )
                )
                peakInFlight = max(peakInFlight, inFlight.count)
            }
        }

        admit()

        while !inFlight.isEmpty, now < scenario.horizonMilliseconds {
            guard let earliest = inFlight.map(\.completesAt).min() else { break }
            now = max(now, earliest)

            var finishing: [InFlight] = []
            var remaining: [InFlight] = []
            remaining.reserveCapacity(inFlight.count)
            for request in inFlight {
                if request.completesAt <= now {
                    finishing.append(request)
                } else {
                    remaining.append(request)
                }
            }
            inFlight = remaining

            for request in finishing {
                let attemptLatency = Saturating.subtract(request.completesAt, request.issuedAt)
                if request.shed {
                    dropped = Saturating.add(dropped, 1)
                    // Back on the queue, and its clock keeps running: the
                    // waiting is charged to the chunk, which is where the user
                    // experiences it.
                    pending.append(request.chunkIndex)
                    controller.observe(
                        RequestSample(
                            roundTrip: .milliseconds(attemptLatency),
                            inFlight: Saturating.add(inFlight.count, 1),
                            outcome: .dropped
                        )
                    )
                } else {
                    completed = Saturating.add(completed, 1)
                    let admittedAt = firstAdmittedAt[request.chunkIndex] ?? request.issuedAt
                    latencies.append(Saturating.subtract(request.completesAt, admittedAt))
                    controller.observe(
                        RequestSample(
                            roundTrip: .milliseconds(attemptLatency),
                            inFlight: Saturating.add(inFlight.count, 1),
                            outcome: .completed
                        )
                    )
                }
            }

            admit()

            // Nothing in flight and work left means the limiter has wedged.
            // Nudging the clock lets a scheduled capacity change unblock it; the
            // horizon stops an infinite loop either way.
            if inFlight.isEmpty, !pending.isEmpty {
                now = Saturating.add(now, 1)
                admit()
            }
        }

        return Result(
            completionMilliseconds: now,
            completedChunks: completed,
            droppedRequests: dropped,
            latenciesMilliseconds: latencies.sorted(),
            peakInFlight: peakInFlight,
            finalLimit: controller.currentLimit
        )
    }

    /// Runs the same scenario against a fixed limit and against the gradient
    /// controller, so the two can be compared on identical conditions.
    public struct Comparison: Sendable, Equatable {
        public let fixed: Result
        public let adaptive: Result
        public let fixedLimit: Int

        /// How many times worse the fixed limiter's p95 latency is.
        public var p95Ratio: Double {
            Saturating.ratio(
                Double(fixed.p95LatencyMilliseconds),
                Double(adaptive.p95LatencyMilliseconds),
                fallback: 1.0
            )
        }

        /// Adaptive throughput as a fraction of fixed throughput. A value near
        /// 1.0 is the point: the latency win is not paid for in throughput.
        public var throughputRatio: Double {
            Saturating.ratio(
                adaptive.throughputPerSecond,
                fixed.throughputPerSecond,
                fallback: 1.0
            )
        }
    }

    public static func compare(
        scenario: Scenario = .capacityCollapsesMidTransfer,
        fixedLimit: Int = 8,
        configuration: GradientLimiter.Configuration = .uploadPipeline
    ) -> Comparison {
        Comparison(
            fixed: run(limiter: FixedLimiter(fixedLimit), scenario: scenario),
            adaptive: run(
                limiter: GradientLimiter(configuration: configuration),
                scenario: scenario
            ),
            fixedLimit: fixedLimit
        )
    }
}
