import XCTest
@testable import AdaptiveTransfer

/// The experiment is where the README's numbers come from, so the suite pins
/// the shape of the claim rather than transcribing figures into prose that
/// quietly stops being true.
final class CapacityExperimentTests: XCTestCase {

    /// Pins every figure the library README publishes.
    ///
    /// The earlier version of this test ran `compare()` twice in one process
    /// and asserted the results matched — which passes for any deterministic
    /// function, including one that returns a constant, and would not have
    /// noticed the table going stale. Exact expected values are the only form
    /// of this test that does anything: change the control law and this file
    /// turns red, which is what the README's claim to that effect requires.
    func testPublishedFiguresAreExact() {
        let comparison = CapacityExperiment.compare()

        XCTAssertEqual(comparison.fixed.completedChunks, 300)
        XCTAssertEqual(comparison.fixed.droppedRequests, 0)
        XCTAssertEqual(comparison.fixed.completionMilliseconds, 5_400)
        XCTAssertEqual(comparison.fixed.medianLatencyMilliseconds, 160)
        XCTAssertEqual(comparison.fixed.p95LatencyMilliseconds, 160)
        XCTAssertEqual(comparison.fixed.p99LatencyMilliseconds, 160)
        XCTAssertEqual(comparison.fixed.peakInFlight, 8)
        XCTAssertEqual(comparison.fixed.finalLimit, 8)

        XCTAssertEqual(comparison.adaptive.completedChunks, 300)
        XCTAssertEqual(comparison.adaptive.droppedRequests, 12)
        XCTAssertEqual(comparison.adaptive.completionMilliseconds, 5_775)
        XCTAssertEqual(comparison.adaptive.medianLatencyMilliseconds, 80)
        XCTAssertEqual(comparison.adaptive.p95LatencyMilliseconds, 100)
        XCTAssertEqual(comparison.adaptive.p99LatencyMilliseconds, 705)
        XCTAssertEqual(comparison.adaptive.peakInFlight, 22)
        XCTAssertEqual(comparison.adaptive.finalLimit, 4)
    }

    /// The other two rows of the README's table.
    func testPublishedCollapseFiguresAreExact() {
        let sixteen = CapacityExperiment.run(
            limiter: FixedLimiter(16),
            scenario: .capacityCollapsesMidTransfer
        )
        XCTAssertEqual(sixteen.completedChunks, 55)
        XCTAssertEqual(sixteen.droppedRequests, 29_985)

        let thirtyTwo = CapacityExperiment.run(
            limiter: FixedLimiter(32),
            scenario: .capacityCollapsesMidTransfer
        )
        XCTAssertEqual(thirtyTwo.completedChunks, 71)
        XCTAssertEqual(thirtyTwo.droppedRequests, 29_977)

        let four = CapacityExperiment.run(
            limiter: FixedLimiter(4),
            scenario: .capacityCollapsesMidTransfer
        )
        XCTAssertEqual(four.completedChunks, 300)
        XCTAssertEqual(four.droppedRequests, 0)
        XCTAssertEqual(four.completionMilliseconds, 5_800)
        XCTAssertEqual(four.p95LatencyMilliseconds, 80)
    }

    func testBothStrategiesCompleteEveryChunk() {
        let comparison = CapacityExperiment.compare()
        XCTAssertEqual(comparison.fixed.completedChunks, 300)
        XCTAssertEqual(comparison.adaptive.completedChunks, 300)
    }

    /// The headline claim: when capacity drops and the client is not told, a
    /// fixed limit converts the excess into queueing latency.
    func testFixedLimitPaysMateriallyWorseTailLatency() {
        let comparison = CapacityExperiment.compare()
        XCTAssertGreaterThan(
            comparison.fixed.p95LatencyMilliseconds,
            comparison.adaptive.p95LatencyMilliseconds,
            "the fixed limiter should queue more than the adaptive one"
        )
        XCTAssertGreaterThan(comparison.p95Ratio, 1.5)
    }

    /// The other half of the claim, and the one that makes it worth shipping:
    /// the latency win is not bought with throughput.
    func testTheLatencyWinIsNotPaidForInThroughput() {
        let comparison = CapacityExperiment.compare()
        XCTAssertGreaterThan(
            comparison.throughputRatio, 0.75,
            "adaptive throughput collapsed; the controller is too timid"
        )
    }

    func testTheAdaptiveControllerConvergesNearActualCapacity() {
        let comparison = CapacityExperiment.compare()
        // Capacity ends at 3. The controller should settle in that
        // neighbourhood rather than at the fixed 8 it started near.
        XCTAssertLessThan(comparison.adaptive.finalLimit, 8)
        XCTAssertGreaterThanOrEqual(comparison.adaptive.finalLimit, 1)
    }

    func testFixedLimiterKeepsOfferingTheSameConcurrencyAfterCapacityDrops() {
        let comparison = CapacityExperiment.compare()
        XCTAssertEqual(comparison.fixed.finalLimit, comparison.fixedLimit)
        XCTAssertEqual(comparison.fixed.peakInFlight, comparison.fixedLimit)
    }

    func testZeroChunkScenarioTerminatesAndReportsNothing() {
        let result = CapacityExperiment.run(
            limiter: GradientLimiter(),
            scenario: .init(chunkCount: 0, server: SimulatedServer())
        )
        XCTAssertEqual(result.completedChunks, 0)
        XCTAssertEqual(result.latenciesMilliseconds, [])
        XCTAssertEqual(result.p95LatencyMilliseconds, 0, "percentile of nothing must not trap")
        XCTAssertEqual(result.throughputPerSecond, 0)
    }

    /// `percentile` is nearest-rank over a sorted array, so asserting
    /// `p50 <= p95 <= p99` would be asserting something the implementation
    /// computes by construction. These are the cases where it could actually be
    /// wrong: the clamps at both ends, and a known fixture where the answer can
    /// be worked out by hand.
    func testPercentileIsNearestRankAndClampsItsInput() {
        let result = CapacityExperiment.Result(
            completionMilliseconds: 1_000,
            completedChunks: 10,
            droppedRequests: 0,
            latenciesMilliseconds: [10, 20, 30, 40, 50, 60, 70, 80, 90, 100],
            peakInFlight: 4,
            finalLimit: 4
        )
        XCTAssertEqual(result.percentile(50), 50)     // rank 5 -> index 4
        XCTAssertEqual(result.percentile(95), 90)      // rank 9 (integer division) -> index 8
        XCTAssertEqual(result.percentile(10), 10)
        XCTAssertEqual(result.percentile(100), 100)
        XCTAssertEqual(result.percentile(0), 10)      // clamped to the first
        XCTAssertEqual(result.percentile(-10), 10)    // clamped, must not trap
        XCTAssertEqual(result.percentile(500), 100)   // clamped, must not trap
    }

    /// The horizon is the only thing between a wedged limiter and an infinite
    /// loop in CI, so it is asserted rather than trusted.
    func testTheHorizonBoundsTheSimulation() {
        let result = CapacityExperiment.run(
            limiter: FixedLimiter(1),
            scenario: .init(
                chunkCount: 100_000,
                server: SimulatedServer(initialCapacity: 1, serviceTimeMilliseconds: 50),
                horizonMilliseconds: 1_000
            )
        )
        XCTAssertLessThanOrEqual(result.completionMilliseconds, 1_100)
        XCTAssertLessThan(result.completedChunks, 100_000)
    }

    func testSimulatedServerModelsQueueingOnlyAboveCapacity() {
        let server = SimulatedServer(initialCapacity: 4, serviceTimeMilliseconds: 50)
        XCTAssertEqual(server.serviceTimeMilliseconds(atMilliseconds: 0, inFlight: 1), 50)
        XCTAssertEqual(server.serviceTimeMilliseconds(atMilliseconds: 0, inFlight: 4), 50)
        XCTAssertEqual(server.serviceTimeMilliseconds(atMilliseconds: 0, inFlight: 8), 100)
        XCTAssertEqual(server.serviceTimeMilliseconds(atMilliseconds: 0, inFlight: 12), 150)
    }

    func testCapacityChangesApplyAtTheRightInstant() {
        let server = SimulatedServer(
            initialCapacity: 8,
            capacityChanges: [
                .init(atMilliseconds: 1_000, capacity: 4),
                .init(atMilliseconds: 2_000, capacity: 2)
            ]
        )
        XCTAssertEqual(server.capacity(atMilliseconds: 0), 8)
        XCTAssertEqual(server.capacity(atMilliseconds: 999), 8)
        XCTAssertEqual(server.capacity(atMilliseconds: 1_000), 4)
        XCTAssertEqual(server.capacity(atMilliseconds: 5_000), 2)
    }

    func testCapacityChangesAreAppliedInTimeOrderRegardlessOfInputOrder() {
        let server = SimulatedServer(
            initialCapacity: 8,
            capacityChanges: [
                .init(atMilliseconds: 2_000, capacity: 2),
                .init(atMilliseconds: 1_000, capacity: 4)
            ]
        )
        XCTAssertEqual(server.capacity(atMilliseconds: 1_500), 4)
        XCTAssertEqual(server.capacity(atMilliseconds: 2_500), 2)
    }

    func testServerShedsLoadPastItsRejectionThreshold() {
        let server = SimulatedServer(
            initialCapacity: 4,
            rejectionThreshold: 2.0
        )
        XCTAssertFalse(server.rejects(atMilliseconds: 0, inFlight: 8))
        XCTAssertTrue(server.rejects(atMilliseconds: 0, inFlight: 9))
    }

    /// The sharper form of the claim, and the one that makes a fixed limit
    /// indefensible rather than merely suboptimal.
    ///
    /// Guessing too *low* costs a little throughput and nothing else. Guessing
    /// too high does not cost latency — past the point where the server starts
    /// shedding, it costs the whole transfer. At a fixed limit of 16 against a
    /// capacity of 2, this scenario completes 55 of 300 chunks inside ten
    /// minutes of virtual time and burns nearly thirty thousand shed requests
    /// doing it. The client is not slow; it is a retry storm that happens to be
    /// wearing an upload's clothes.
    ///
    /// That asymmetry is the argument. A team cannot pick a safe number, because
    /// the safe side of the number is not where the throughput is, and the
    /// unsafe side is a cliff rather than a slope.
    func testAFixedGuessAboveCapacityCollapsesTheTransferEntirely() {
        for guess in [16, 32] {
            let result = CapacityExperiment.run(
                limiter: FixedLimiter(guess),
                scenario: .capacityCollapsesMidTransfer
            )
            XCTAssertLessThan(
                result.completedChunks, 150,
                "fixed \(guess) unexpectedly completed \(result.completedChunks)/300"
            )
            XCTAssertGreaterThan(
                result.droppedRequests, 10_000,
                "fixed \(guess) should be shedding catastrophically"
            )
        }
    }

    /// The controller's actual value proposition, stated as a test: it finishes
    /// without having been told the answer, and it does not fall off the cliff.
    func testTheAdaptiveControllerFinishesWithoutBeingToldTheRightNumber() {
        let adaptive = CapacityExperiment.run(
            limiter: GradientLimiter(),
            scenario: .capacityCollapsesMidTransfer
        )
        let bestFixedGuess = CapacityExperiment.run(
            limiter: FixedLimiter(4),
            scenario: .capacityCollapsesMidTransfer
        )

        XCTAssertEqual(adaptive.completedChunks, 300)
        XCTAssertLessThan(adaptive.droppedRequests, 100, "the controller's probing must stay cheap")
        // Within 15% of the completion time of the single best fixed guess for
        // this scenario — a guess that could only have been made by knowing the
        // capacity schedule in advance.
        XCTAssertLessThan(
            Double(adaptive.completionMilliseconds),
            Double(bestFixedGuess.completionMilliseconds) * 1.15
        )
    }

    /// Counter-evidence, kept in the suite on purpose.
    ///
    /// A fixed limit that happens to be *right* beats the controller, because
    /// the controller pays for probing and the oracle does not. Any honest
    /// account of this design has to say so, and a test suite that only
    /// contained results flattering the thing it tests would not be worth
    /// reading. The claim is not "adaptive is faster"; it is "adaptive does not
    /// need to be right in advance, and its worst case is bounded".
    func testAPerfectlyTunedFixedGuessStillBeatsTheController() {
        let oracle = CapacityExperiment.run(
            limiter: FixedLimiter(4),
            scenario: .capacityCollapsesMidTransfer
        )
        let adaptive = CapacityExperiment.run(
            limiter: GradientLimiter(),
            scenario: .capacityCollapsesMidTransfer
        )
        XCTAssertLessThanOrEqual(
            oracle.p95LatencyMilliseconds, adaptive.p95LatencyMilliseconds,
            "if the controller beat the oracle, the model is flattering it"
        )
        XCTAssertLessThanOrEqual(oracle.droppedRequests, adaptive.droppedRequests)
    }

    /// Prints the numbers the README quotes, so a reviewer can regenerate them
    /// from a single test run rather than taking prose on trust.
    func testPublishNumbersForTheReadme() {
        let comparison = CapacityExperiment.compare()
        for guess in [4, 8, 16, 32] {
            let result = CapacityExperiment.run(
                limiter: FixedLimiter(guess),
                scenario: .capacityCollapsesMidTransfer
            )
            print("fixed \(guess): completed=\(result.completedChunks)/300 "
                + "shed=\(result.droppedRequests) done=\(result.completionMilliseconds)ms "
                + "p50=\(result.medianLatencyMilliseconds)ms p95=\(result.p95LatencyMilliseconds)ms "
                + "p99=\(result.p99LatencyMilliseconds)ms peak=\(result.peakInFlight)")
        }
        print("""

        === CapacityExperiment.compare() ===
        scenario: 300 chunks, capacity 8 -> 2 at 200ms, 40ms service time
        fixed(\(comparison.fixedLimit)):  p50=\(comparison.fixed.medianLatencyMilliseconds)ms \
        p95=\(comparison.fixed.p95LatencyMilliseconds)ms \
        p99=\(comparison.fixed.p99LatencyMilliseconds)ms \
        done=\(comparison.fixed.completionMilliseconds)ms \
        peak=\(comparison.fixed.peakInFlight) \
        dropped=\(comparison.fixed.droppedRequests) \
        final=\(comparison.fixed.finalLimit)
        adaptive: p50=\(comparison.adaptive.medianLatencyMilliseconds)ms \
        p95=\(comparison.adaptive.p95LatencyMilliseconds)ms \
        p99=\(comparison.adaptive.p99LatencyMilliseconds)ms \
        done=\(comparison.adaptive.completionMilliseconds)ms \
        peak=\(comparison.adaptive.peakInFlight) \
        dropped=\(comparison.adaptive.droppedRequests) \
        final=\(comparison.adaptive.finalLimit)
        p95 ratio: \(String(format: "%.2f", comparison.p95Ratio))x
        throughput ratio (adaptive/fixed): \(String(format: "%.3f", comparison.throughputRatio))
        ====================================

        """)
    }
}
